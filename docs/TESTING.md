# 测试与验收

## 运行离线检查

在安装了 Apple CommandLineTools 的 Mac 终端运行：

```sh
./scripts/test.sh
```

默认运行30项检查并跳过两项长测试。运行全部32项：

```sh
RECORDER_LONG_TEST=1 RECORDER_LONG_EXPORT=1 ./scripts/test.sh
```

报告写入本机 `artifacts/self-test-report.json`。测试使用临时合成音频，播放器测试为静音；不打开真实麦克风或系统音频采集。废纸篓检查只移入并恢复一个带UUID名称的自建临时文件，不操作已有录音。长测试可能临时占用约3GB磁盘空间，结束后清理。

## 已验证的范围

v0.4.0的32项完整离线检查已在开发用 Apple Silicon Mac 上通过，覆盖：

- 三种来源隔离、输入回退、重连退避、旧设备代次过滤、时戳异常处理。
- 暂停区间排除、同文件继续、暂停中保存和缓存恢复。
- 来源/麦克风热切换边界、停用来源缓存清除、单源/双源增益调整。
- 旧会话元数据兼容、录音列表、播放器暂停/定位/停止/结束重播。
- 废纸篓删除与恢复、无效目标拒绝。
- PCM格式解码、采样率转换、混音、静音时间、缓存片段、导出校验和失败重试。
- 4小时合成时间线：691,200,000帧；1440个PCM片段导出单个4小时M4A，并检查代表性位置及末尾解码。

v0.4.2 使用双栏录音与播放界面，并更新为透明圆角图标。已检查原生窗口、图标透明通道、录音列表与播放器，以及安装包完整性和签名。音频核心及离线测试源码与 v0.4 一致，沿用上述完整离线基线；v0.4.2 没有重新执行长测试。

这些结果来自离线合成数据。它们不证明真实设备切换没有缺音，也不等于完成了4小时实际录制。

## 转写 Beta 检查

```sh
python3 -m unittest discover -s Tests -p 'TranscriptionWorkerTests.py'
```

检查覆盖分段时间戳、短尾合并、源文件变化、失败后保留部分结果和说话人标签的片段范围。独立运行环境还在禁止网络、禁止读取开发机原 FunASR/Conda 环境的条件下，用自建合成中文语音验证了普通转写和说话人模式。合成检查不代表真实会议音频的识别准确度或长时稳定性。

## 真实设备验收

必须由使用者主动点击“开始录音”并授权：

1. 分别验证仅系统声、仅麦克风、双路模式的实际内容。
2. 暂停几秒再继续，确认同一文件且成品不包含暂停时段；验证暂停后直接结束保存。
3. 录制中切换来源和可用麦克风，确认选择生效、旧声音不再混入；新增权限被拒绝时保留原配置。
4. 插拔耳机，检查录音是否继续、输入是否回退/恢复，回放切换位置。硬件切换可能有短暂静音。
5. 验证关闭窗口/菜单栏操作、锁屏、长时间录制、设备断开及磁盘不足后的保存边界。

## 打包核对

```sh
./scripts/build.sh
./scripts/install.sh
```

构建产生本机签名的应用与 `dist/轻录-mac.zip`；安装脚本先备份旧应用，并核验签名。当前没有用于第三方分发的 Developer ID 签名和公证。

`scripts/verify-release.py` 是开发者发布检查脚本，需要本机有完整报告 `artifacts/final-test-report.json`、日志 `artifacts/final-test-run.log` 和安装后的应用。可在正常终端用以下方式准备报告后运行：

```sh
set -o pipefail
RECORDER_LONG_TEST=1 RECORDER_LONG_EXPORT=1 .build/release/RecorderSelfTest \
  --report artifacts/final-test-report.json 2>&1 | tee artifacts/final-test-run.log
python3 scripts/verify-release.py
```

它会检查版本、完整测试清单、安装/解压后的签名、UTF-8路径、二进制及 PNG/ICNS 图标一致性。生成的路径与哈希清单只留在本机，不属于公开源码。
