# Codex Mac Intel 转换工具（非官方）

用于将官方 `Codex.dmg` 重新打包为可在 Intel Mac 上运行的 macOS 应用镜像（非官方方案）。

思路与 Linux 社区移植版类似：  
[Codex App for Linux (unofficial)](https://github.com/areu01or00/Codex-App-Linux/)

## 仓库内容

- `build-intel.sh`：主构建脚本
- `.gitignore`：忽略临时构建产物
- `package.json`：可选的脚本入口封装

## 环境要求

- macOS
- `bash`、`hdiutil`、`ditto`、`codesign`
- Node.js + npm（用于下载 Electron/原生依赖并重建）

## 快速使用

1. 将原始 `Codex.dmg` 放在仓库目录的上一级（即默认路径 `../Codex.dmg`）。
2. 执行：

```bash
chmod +x ./build-intel.sh
./build-intel.sh
```

或指定绝对路径：

```bash
./build-intel.sh /absolute/path/to/Codex.dmg
```

## 输出文件

- `CodexAppMacIntel.dmg`：构建完成的 Intel 版本安装包
- `log.txt`：完整构建日志
- `.tmp/`：构建临时目录（失败时用于排错）

## GitHub Actions 发布

- 手动运行 `.github/workflows/build-intel-dmg.yml` 后，工作流除了上传 `artifact`，还会把最新构建出的 DMG 发布到仓库的 GitHub Release。
- Release 固定使用标签 `intel-dmg-latest`，每次成功构建都会覆盖同名资源文件，方便直接下载最新的 Intel 安装包。

## 安装后安全提示（Gatekeeper）

如果 macOS 提示“无法验证开发者”或阻止打开，可按以下方式处理：

1. 先在 Finder 中双击 `/Applications/Codex.app` 一次，让系统记录拦截项。
2. 打开：`系统设置 -> 隐私与安全性`，在页面底部点击“仍要打开”。
3. 若仍被拦截，可执行去隔离标记命令：

```bash
xattr -dr com.apple.quarantine /Applications/Codex.app
```

完成后再次启动应用即可。
