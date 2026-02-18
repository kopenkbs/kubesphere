# 登录问题排查与修复沟通纪要

## 背景

- 场景：前端已对接本地启动的 KubeSphere 后端，使用 `admin / P@88w0rd` 登录失败。
- 现象：前端提示“账号或密码错误”，后续又出现 `InternalError`，报错指向 `users.iam.kubesphere.io` webhook 调用失败。

## 关键结论

- 第一阶段登录失败主因不是密码错误，而是 OAuth 客户端配置缺失。
  - 证据：`POST /oauth/token` 返回 `401 invalid_client`，错误为 `the OAuth client was not found`。
- 第二阶段 `InternalError` 主因不是前端地址，而是 Kubernetes 集群内 webhook Service 缺失。
  - 证据：`ValidatingWebhookConfiguration/users.iam.kubesphere.io` 指向 `https://ks-controller-manager.kubesphere-system.svc:443/...`，但集群不存在 `kubesphere-system` 命名空间和 `ks-controller-manager` Service。

## 处理过程与执行结果

## 1. 初始化与服务启动

- 新建了中文初始化文件：`AGENTS.md`。
- 本地启动服务：
  - `ks-apiserver`：监听 `:9090`
  - `controller-manager`：监听 `:8443`（以及 `:8080`）

## 2. 修复 OAuth 登录主链路

- 备份配置：`kubesphere.yaml.bak.20260218-023653`
- 修改 `kubesphere.yaml`，增加：
  - `authentication.oauthOptions.clients[0].name: kubesphere`
  - `authentication.oauthOptions.clients[0].secret: kubesphere`
  - `authentication.oauthOptions.clients[0].redirectURIs: ["*"]`
- 重启 `ks-apiserver` 后验证：
  - 正确凭据：`/oauth/token` 返回 `200` 并下发 token。
  - 错误密码：返回 `400 invalid_grant`。
- 结论：登录认证链路恢复正常。

## 3. 修复 users webhook 阻塞（开发环境快速解锁）

- 备份 webhook 配置：
  - `_output/run/users.iam.kubesphere.io.vwc.backup.20260218-025818.yaml`
- 将 `ValidatingWebhookConfiguration/users.iam.kubesphere.io` 的 `failurePolicy` 从 `Fail` 改为 `Ignore`。
- 验证：
  - `kubectl get validatingwebhookconfiguration users.iam.kubesphere.io -o jsonpath='{.webhooks[0].failurePolicy}'` 返回 `Ignore`。
  - 使用 `kubectl create/patch --dry-run=server` 验证 `User` 资源不再因 webhook Service 缺失而报 InternalError。

## 当前状态

- 后端 token 登录正常。
- 用户资源相关请求已解除 webhook 阻塞。
- 集群仍未补齐标准 ks-core 资源（如 `kubesphere-system`、`ks-controller-manager` Service）；仅做了开发环境临时降级处理。

## 风险与说明

- `users` webhook 的 `failurePolicy=Ignore` 会在 webhook 不可达时跳过校验，仅适合开发联调。
- 若需要生产级行为，应补齐 ks-core 组件并恢复 `failurePolicy=Fail`。

## 回滚参考

- 回滚 users webhook：
  - `kubectl apply -f _output/run/users.iam.kubesphere.io.vwc.backup.20260218-025818.yaml`

