#include "desktop_assistant.h"
#include "resource.h"
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <dwmapi.h>
#include <algorithm>

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
namespace {
constexpr int kToggle = 0xA101, kCapture = 0xA102;
constexpr UINT kTray = WM_APP + 0x51;
constexpr wchar_t kRegionClass[] = L"AipuOcrRegionSelection";
struct BitmapOwner { HBITMAP value; ~BitmapOwner() { if (value) DeleteObject(value); } };
std::vector<uint8_t> CapturePng(const RECT& rect) {
  const int width = rect.right - rect.left, height = rect.bottom - rect.top;
  if (width < 2 || height < 2 || static_cast<int64_t>(width) * height > 24000000) return {};
  HDC screen = GetDC(nullptr);
  if (!screen) return {};
  HDC memory = CreateCompatibleDC(screen);
  BitmapOwner bitmap{CreateCompatibleBitmap(screen, width, height)};
  bool copied = false;
  if (memory && bitmap.value) {
    const HGDIOBJ previous = SelectObject(memory, bitmap.value);
    copied = BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT) != 0;
    SelectObject(memory, previous);
  }
  if (memory) DeleteDC(memory);
  ReleaseDC(nullptr, screen);
  if (!copied) return {};
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return {};
  ComPtr<IWICBitmap> image;
  if (FAILED(factory->CreateBitmapFromHBITMAP(bitmap.value, nullptr, WICBitmapIgnoreAlpha, &image))) return {};
  ComPtr<IWICBitmapScaler> scaled;
  if (FAILED(factory->CreateBitmapScaler(&scaled))) return {};
  const double factor = std::min(1.0, 1200.0 / std::max(width, height));
  const UINT out_width = std::max(2U, static_cast<UINT>(width * factor));
  const UINT out_height = std::max(2U, static_cast<UINT>(height * factor));
  if (FAILED(scaled->Initialize(image.Get(), out_width, out_height, WICBitmapInterpolationModeFant))) return {};
  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) || FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) return {};
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> options;
  if (FAILED(encoder->CreateNewFrame(&frame, &options)) || FAILED(frame->Initialize(options.Get())) || FAILED(frame->SetSize(out_width, out_height))) return {};
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format))) return {};
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) || FAILED(converter->Initialize(scaled.Get(), format, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return {};
  if (FAILED(frame->WriteSource(converter.Get(), nullptr)) || FAILED(frame->Commit()) || FAILED(encoder->Commit())) return {};
  STATSTG stats{};
  if (FAILED(stream->Stat(&stats, STATFLAG_NONAME)) || stats.cbSize.QuadPart == 0 || stats.cbSize.QuadPart > 8 * 1024 * 1024) return {};
  LARGE_INTEGER zero{};
  if (FAILED(stream->Seek(zero, STREAM_SEEK_SET, nullptr))) return {};
  const auto length = static_cast<ULONG>(stats.cbSize.QuadPart);
  std::vector<uint8_t> bytes(length);
  ULONG read = 0;
  if (FAILED(stream->Read(bytes.data(), length, &read)) || read != length) return {};
  return bytes;
}
}

DesktopAssistant::DesktopAssistant(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  explorer_restart_ = RegisterWindowMessageW(L"TaskbarCreated");
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "aipu/desktop-assistant", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      bool enabled = false;
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      if (args) {
        const auto found = args->find(EncodableValue("enabled"));
        if (found != args->end()) { const auto* value = std::get_if<bool>(&found->second); enabled = value && *value; }
      }
      if (Configure(enabled)) result->Success(EncodableValue(enabled));
      else result->Error("hotkey_unavailable", "Global shortcut is already in use");
    } else if (call.method_name() == "capture") { Capture(); result->Success(); }
    else result->NotImplemented();
  });
}
DesktopAssistant::~DesktopAssistant() {
  lifetime_.reset();
  Configure(false);
  if (overlay_) DestroyWindow(overlay_);
}
bool DesktopAssistant::AddTray() {
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; icon.uCallbackMessage = kTray;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"\u827e\u666e\u5feb\u6377\u52a9\u624b");
  return Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
}
bool DesktopAssistant::Configure(bool enabled) {
  UnregisterHotKey(window_, kToggle); UnregisterHotKey(window_, kCapture);
  NOTIFYICONDATAW icon{}; icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon); enabled_ = false;
  if (!enabled) return true;
  if (!RegisterHotKey(window_, kToggle, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, VK_SPACE) ||
      !RegisterHotKey(window_, kCapture, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'O')) { Configure(false); return false; }
  if (!AddTray()) { Configure(false); return false; }
  enabled_ = true; return true;
}
void DesktopAssistant::Show() { ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW); SetForegroundWindow(window_); }
bool DesktopAssistant::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result) {
  if (message == WM_CLOSE && enabled_) { ShowWindow(window_, SW_HIDE); *result = 0; return true; }
  if (message == explorer_restart_ && enabled_) { AddTray(); *result = 0; return true; }
  if (message == WM_HOTKEY && enabled_) {
    if (wparam == kToggle) { if (IsWindowVisible(window_) && GetForegroundWindow() == window_) ShowWindow(window_, SW_HIDE); else Show(); }
    else if (wparam == kCapture) Capture();
    else return false;
    *result = 0; return true;
  }
  if (message == kTray) {
    if (lparam == WM_LBUTTONDBLCLK) Show();
    else if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"\u6253\u5f00\u827e\u666e");
      AppendMenuW(menu, MF_STRING, 2, L"\u622a\u56fe OCR");
      AppendMenuW(menu, MF_STRING, 3, L"OCR \u4efb\u52a1\u4e2d\u5fc3");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, 4, L"\u9000\u51fa\u827e\u666e");
      POINT point; GetCursorPos(&point); SetForegroundWindow(window_);
      const int command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, point.x, point.y, 0, window_, nullptr);
      DestroyMenu(menu); PostMessage(window_, WM_NULL, 0, 0);
      if (command == 1) Show(); else if (command == 2) Capture();
      else if (command == 3) { Show(); channel_->InvokeMethod("tasks", nullptr); }
      else if (command == 4) { Configure(false); PostMessage(window_, WM_CLOSE, 0, 0); }
    }
    *result = 0; return true;
  }
  return false;
}
void DesktopAssistant::Capture() {
  if (capturing_) return;
  capturing_ = true;
  const std::weak_ptr<bool> alive = lifetime_;
  channel_->InvokeMethod("beginCapture", nullptr, std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
    [this, alive](const EncodableValue* value) {
      if (alive.expired()) return;
      const auto* token = value ? std::get_if<std::string>(value) : nullptr;
      if (!token || token->empty()) { capturing_ = false; Show(); return; }
      token_ = *token; SelectRegion();
    }, [this, alive](const auto&, const auto&, const auto*) { if (!alive.expired()) { capturing_ = false; Show(); } },
    [this, alive]() { if (!alive.expired()) { capturing_ = false; Show(); } }));
}
void DesktopAssistant::SelectRegion() {
  POINT cursor; GetCursorPos(&cursor);
  MONITORINFO info{}; info.cbSize = sizeof(info);
  if (!GetMonitorInfo(MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST), &info)) { SendCapture({}, true); return; }
  monitor_ = info.rcMonitor;
  WNDCLASSW type{}; type.lpfnWndProc = RegionProc; type.hInstance = GetModuleHandle(nullptr);
  type.lpszClassName = kRegionClass; type.hCursor = LoadCursor(nullptr, IDC_CROSS);
  type.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&type);
  ShowWindow(window_, SW_HIDE); selected_ = {}; dragging_ = false; finishing_ = false;
  overlay_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, kRegionClass, L"OCR region", WS_POPUP,
      monitor_.left, monitor_.top, monitor_.right - monitor_.left, monitor_.bottom - monitor_.top, nullptr, nullptr, type.hInstance, this);
  if (!overlay_) { SendCapture({}, true); Show(); return; }
  SetLayeredWindowAttributes(overlay_, 0, 60, LWA_ALPHA);
  ShowWindow(overlay_, SW_SHOW); SetForegroundWindow(overlay_); SetFocus(overlay_);
}
LRESULT CALLBACK DesktopAssistant::RegionProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<DesktopAssistant*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<DesktopAssistant*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(window, message, wparam, lparam);
  if (message == WM_LBUTTONDOWN) { self->start_ = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}; self->dragging_ = true; SetCapture(window); return 0; }
  if (message == WM_MOUSEMOVE && self->dragging_) {
    const int x = std::clamp(GET_X_LPARAM(lparam), 0, static_cast<int>(self->monitor_.right - self->monitor_.left));
    const int y = std::clamp(GET_Y_LPARAM(lparam), 0, static_cast<int>(self->monitor_.bottom - self->monitor_.top));
    self->selected_ = {std::min<LONG>(self->start_.x, x), std::min<LONG>(self->start_.y, y), std::max<LONG>(self->start_.x, x), std::max<LONG>(self->start_.y, y)};
    InvalidateRect(window, nullptr, TRUE); return 0;
  }
  if (message == WM_LBUTTONUP && self->dragging_) { self->FinishSelection(false); return 0; }
  if ((message == WM_KEYDOWN && wparam == VK_ESCAPE) || message == WM_KILLFOCUS) { self->FinishSelection(true); return 0; }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint; HDC dc = BeginPaint(window, &paint);
    HPEN pen = CreatePen(PS_SOLID, 2, RGB(255,255,255)); HGDIOBJ old_pen = SelectObject(dc, pen), old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
    Rectangle(dc, self->selected_.left, self->selected_.top, self->selected_.right, self->selected_.bottom);
    SelectObject(dc, old_pen); SelectObject(dc, old_brush); DeleteObject(pen); EndPaint(window, &paint); return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
void DesktopAssistant::FinishSelection(bool cancelled) {
  if (finishing_ || !capturing_) return;
  finishing_ = true; dragging_ = false;
  HWND overlay = overlay_; overlay_ = nullptr;
  ReleaseCapture(); if (overlay) DestroyWindow(overlay); DwmFlush();
  if (cancelled || selected_.right - selected_.left < 4 || selected_.bottom - selected_.top < 4) SendCapture({}, false);
  else {
    const RECT rect{selected_.left + monitor_.left, selected_.top + monitor_.top, selected_.right + monitor_.left, selected_.bottom + monitor_.top};
    const auto bytes = CapturePng(rect); SendCapture(bytes, bytes.empty());
  }
  Show();
}
void DesktopAssistant::SendCapture(const std::vector<uint8_t>& bytes, bool failed) {
  EncodableMap args{{EncodableValue("token"), EncodableValue(token_)}};
  const std::string method = !bytes.empty() ? "captured" : failed ? "captureFailed" : "captureCancelled";
  if (!bytes.empty()) args[EncodableValue("bytes")] = EncodableValue(bytes);
  token_.clear(); capturing_ = false;
  channel_->InvokeMethod(method, std::make_unique<EncodableValue>(args));
}
