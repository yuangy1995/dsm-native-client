# 参与开发

[English](CONTRIBUTING.en.md)

## 仓库工作方式

在现有 `main` 主分支工作，开始前阅读 [AGENTS.md](AGENTS.md)、检查工作区与相关差异并保留已有改动。不要自动创建功能分支或临时验证分支。

用户明确要求提交时，将当前任务相关改动在 `main` 提交并推送 `origin/main`：先完成适度验证，再核对远端新提交，按正常历史整合，不强制推送或改写共享历史。未获请求时不暂存、提交、推送或创建 PR；提交请求不包含发布安装包、标签或 PR 的授权。

## 提交要求

- 一个提交只处理一个明确目标。
- 修改行为时同步更新对应文档、契约和进度状态。
- 提交前确认没有秘密、真实响应、抓包或用户文件。
- 代码注释使用中文，公共类型和方法命名遵循平台语言习惯。

## API 变更

API 相关修改必须说明：

- 接口属于官方、混合还是内部。
- 已验证的 DSM build 和套件版本。
- 请求版本、路径、参数编码和错误处理。
- 功能不可用时的降级行为。

## Pull Request

Pull Request 应包含变更内容、影响平台、验证方法、安全影响和文档更新情况。

## 社区兼容性报告

普通用户可以使用 GitHub 的“社区兼容性报告 / Community compatibility report”表单。提交前请阅读：

- [`社区兼容性计划`](docs/compatibility/COMMUNITY_COMPATIBILITY_PROGRAM_ZH.md)
- [`社区兼容性测试指南`](docs/compatibility/COMMUNITY_TEST_GUIDE_ZH.md)

熟悉 GitHub 的贡献者可以根据 [`example-report.json`](contracts/community-compatibility/examples/example-report.json) 直接提交结构化报告 Pull Request。报告进入仓库前必须完成人工隐私检查，并通过：

```bash
python3 tools/community-compatibility/validate.py
python3 tools/community-compatibility/generate.py
python3 -m unittest discover -s tools/community-compatibility/tests -p 'test_*.py'
```

社区报告不得包含日志、截图、HAR、DSM 原始响应、凭据、地址、唯一设备标识、账号、真实文件名或路径。生成的中英文矩阵不得直接手改。
