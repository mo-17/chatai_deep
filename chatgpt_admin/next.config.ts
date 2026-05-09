import type { NextConfig } from "next";

const csp = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: https://ui-avatars.com http://localhost:3000",
  "connect-src 'self' http://localhost:3000",
  "font-src 'self'",
].join('; ');

const nextConfig: NextConfig = {
  // NextUI v2 SelectItem type incompatible with React 19 JSX; re-enable after upgrading to NextUI v3 / HeroUI
  typescript: {
    ignoreBuildErrors: true,
  },
  experimental: {
    optimizePackageImports: ['lucide-react', '@nextui-org/react', 'recharts'],
  },
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          { key: 'Content-Security-Policy', value: csp },
        ],
      },
    ];
  },
  async rewrites() {
    const backend = process.env.NEXT_PUBLIC_BACKEND || 'http://localhost:3000';
    return [
      { source: '/api/:path*', destination: `${backend}/uapi/:path*` },
      // 静态资源直通，不走 /uapi 前缀
      { source: '/uploads/:path*', destination: `${backend}/uploads/:path*` },
    ];
  },
};

export default nextConfig;
