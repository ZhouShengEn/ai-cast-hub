# AI Cast Hub 代码沙箱镜像
FROM node:20-alpine

# 安装常用工具
RUN apk add --no-cache bash python3 py3-pip curl

# 创建受限用户
RUN adduser -D -h /home/sandbox -s /bin/bash sandbox

# 沙箱工作目录
WORKDIR /tmp/code
RUN chown sandbox:sandbox /tmp/code

# 资源限制由 Docker 运行时控制（--memory, --cpus）
USER sandbox

# 默认命令：执行传入的代码文件
CMD ["node", "/tmp/code/script.js"]
