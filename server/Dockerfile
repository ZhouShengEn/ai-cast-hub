# AI Cast Hub 服务端 Docker 镜像
FROM node:20-alpine

WORKDIR /app

# 复制依赖文件
COPY package.json package-lock.json* ./

# 安装生产依赖
RUN npm ci --omit=dev && npm cache clean --force

# 复制源码
COPY src/ ./src/

# 创建数据目录
RUN mkdir -p /app/data

EXPOSE 3000

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/api/v1/health', r => process.exit(r.statusCode === 200 ? 0 : 1))"

CMD ["node", "src/index.js"]
