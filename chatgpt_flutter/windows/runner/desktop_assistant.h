#ifndef RUNNER_DESKTOP_ASSISTANT_H_
#define RUNNER_DESKTOP_ASSISTANT_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <string>
#include <vector>

class DesktopAssistant {
 public:
  DesktopAssistant(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopAssistant();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam, LRESULT* result);
 private:
  bool Configure(bool enabled);
  void Show();
  void Capture();
  void SelectRegion();
  void FinishSelection(bool cancelled);
  void SendCapture(const std::vector<uint8_t>& bytes, bool failed);
  bool AddTray();
  static LRESULT CALLBACK RegionProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  HWND window_ = nullptr;
  HWND overlay_ = nullptr;
  bool enabled_ = false, capturing_ = false, dragging_ = false, finishing_ = false;
  POINT start_{};
  RECT selected_{}, monitor_{};
  std::string token_;
  UINT explorer_restart_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<bool> lifetime_ = std::make_shared<bool>(true);
};
#endif
