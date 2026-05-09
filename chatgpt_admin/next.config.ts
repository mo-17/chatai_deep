import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // NextUI v2 SelectItem type incompatible with React 19 JSX; re-enable after upgrading to NextUI v3 / HeroUI
  typescript: {
    ignoreBuildErrors: true,
  },
  experimental: {
    optimizePackageImports: ['lucide-react', '@nextui-org/react', 'recharts'],
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
