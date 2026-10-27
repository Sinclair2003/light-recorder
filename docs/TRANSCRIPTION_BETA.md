# 本地转写 Beta

轻录可以在本机使用 FunASR 的中文模型，将录音转成文字。转写是实验功能，需要手动开始。

## 使用

1. 点击主界面的「录音文字转写 Beta」，在转写页面选择录音，也可以点击「导入音频」选择已有文件。
2. 按需选择「区分说话人」，点击「开始转写」。
3. 完成后可复制文字，或导出 TXT 和带时间戳的 JSON。

本次打开应用期间，导入的音频会留在页面列表中；重新打开应用后可再次导入。

可以返回录音页面，任务会继续运行；再次点击「录音文字转写 Beta」可查看进度。转写期间暂不能开始新录音。转写过程中停止或发生错误时，已完成的片段会保留；原音频不会被改写。

独立安装包内包含本地 Python 运行环境和所需模型，转写进程禁止联网，不上传录音。模型加载和长音频处理需要时间；界面按已完成的片段报告进度。

## 实验功能说明

- 人名、数字、专业术语和音频不清晰的内容需要人工核对。
- 长音频按约十分钟分段。说话人编号仅在各片段内有效，不代表跨片段的真实身份。
- 选择说话人区分时，先保存普通转写；说话人处理失败后仍可查看普通结果。
- 转写结果存放在 `~/Library/Application Support/LightRecorder/Transcriptions`。删除录音不会自动删除其文字。

## 构建

普通源码构建需要提供已配置的 FunASR 环境；可在转写页面中选择包含 `.venv` 和本地模型缓存的目录。要把独立运行环境一并打入应用，在准备好兼容的独立运行环境后执行：

```sh
LIGHTRECORDER_FUNASR_ENGINE=/path/to/prepared-engine ./scripts/build.sh
```

如果本机已安装包含转写的轻录，可直接复用安装包中的运行环境：

```sh
LIGHTRECORDER_FUNASR_ENGINE="$HOME/Applications/轻录.app/Contents/Resources/FunASREngine" ./scripts/build.sh
```

模型和 Python 依赖来自各自的上游项目；各模型目录保留了模型卡，Python 依赖的许可文件保留在运行环境中。项目不包含用户录音或转写结果。

开发者可以用一个自行生成的短语音样本记录所需模块，再构建独立环境。以下路径仅示意，`/path/to/python311` 必须是可重定位的 Apple Silicon Python 3.11 发行版；源 FunASR 环境及四个中文模型必须已就绪。

```sh
mkdir -p /tmp/lightrec-audit-job
/path/to/funasr/.venv/bin/python scripts/profile-funasr-engine.py \
  --audio /path/to/synthetic.wav --engine-root /path/to/funasr \
  --job-dir /tmp/lightrec-audit-job --audit /tmp/lightrec-modules.json --speaker
python3 scripts/prepare-funasr-engine.py \
  --python-root /path/to/python311 --source-engine /path/to/funasr \
  --module-audit /tmp/lightrec-modules.json --output /tmp/lightrec-engine
LIGHTRECORDER_FUNASR_ENGINE=/tmp/lightrec-engine ./scripts/build.sh
```

打包完成后应在禁止联网且无法读取开发机源环境的条件下重新验证转写，再用于其他机器。
