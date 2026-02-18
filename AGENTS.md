# KubeSphere Agent 初始化说明（中文）

## 语言与沟通

- 默认使用中文回复。
- 修改代码前先说明将要改动的文件和目的。
- 完成改动后给出变更摘要与验证结果（含未执行项）。

## 项目概览

- 项目：KubeSphere 后端（Go）
- 主要目录：
  - `cmd/`：服务入口（`ks-apiserver`、`controller-manager`）
  - `pkg/`：核心业务逻辑
  - `api/`：API 定义
  - `config/`：CRD、部署配置与 Helm 相关内容
  - `hack/`：构建、校验、生成脚本
  - `test/`：测试代码

## 常用命令

```bash
# 查看帮助
make help

# 构建
make binary
make ks-apiserver
make ks-controller-manager

# 测试
make test

# 代码检查与格式化
make vet
make fmt
make verify-all
```

## 开发约束

- 优先小步修改，避免无关重构。
- 遵循现有 Go 代码风格与目录边界。
- 非必要不要更新 `vendor/`。
- 涉及接口或行为变化时，补充或更新测试。

## 提交前自检建议

```bash
make vet
make test
```

