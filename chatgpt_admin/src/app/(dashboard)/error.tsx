'use client';

export default function DashboardError({
  error,
  reset,
}: {
  error: Error;
  reset: () => void;
}) {
  return (
    <div className="flex flex-col items-center justify-center h-full gap-4">
      <h2 className="text-xl font-semibold">页面加载失败</h2>
      <p className="text-default-500">{error.message}</p>
      <button onClick={reset} className="px-4 py-2 bg-primary text-white rounded">
        重试
      </button>
    </div>
  );
}
