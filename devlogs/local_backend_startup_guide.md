# 本地启动开发指南

## 目标

- 在本机启动 `ks-apiserver` 与 `controller-manager`。
- 前端对接本地后端完成登录、用户管理等联调。
- 明确“本地二进制启动”依赖的 Kubernetes 资源准备步骤（这是关键前置）。

## 一、运行模式说明（重要）

当前采用的是“混合模式”：

- 组件进程：`ks-apiserver`、`controller-manager` 由本机进程启动。
- 集群资源：先把一批 ks-core 基础资源（账号、角色、配置、webhook 等）apply 到 Kubernetes。

如果只启动本地进程、不提前 apply 基础资源，会出现登录异常、角色缺失、webhook 报错等问题。

## 二、前置条件

- 已安装：`go`、`make`、`kubectl`、`helm`。
- kubeconfig 可用（默认 `/home/vscode/.kube/config`）。
- 当前仓库目录：`/IdeaProjects/kubesphere`。

## 三、准备 Kubernetes 基础资源（必做）

## 1) 生成过滤后的资源文件

你当前仓库已经有这两个文件，可直接使用：

- `values-filtered.yaml`
- `ks-core-filtered.yaml`

如果需要重新生成：

```bash
helm template ks-core config/ks-core -f values-filtered.yaml > ks-core-filtered.yaml
```

说明：该 filtered 清单禁用了 `apiserver/controller/console` 的 Deployment，仅保留基础资源。

## 2) 应用 CRD 与基础清单

```bash
kubectl apply -f config/crds
kubectl apply -f ks-core-filtered.yaml
```

## 3) 验证基础资源是否存在

```bash
kubectl get configmap kubesphere-config
kubectl get users.iam.kubesphere.io admin
kubectl get globalroles.iam.kubesphere.io
kubectl get validatingwebhookconfigurations
```

## 4) 你当前 filtered 清单包含哪些关键资源

`ks-core-filtered.yaml` 主要会创建：

- `ServiceAccount kubesphere`
- `ClusterRoleBinding kubesphere`
- `ConfigMap kubesphere-config`
- `User admin`
- 多个 `GlobalRole/GlobalRoleBinding`
- 4 个 `ValidatingWebhookConfiguration`

同时它不会创建：

- `ks-apiserver` Deployment/Service
- `ks-controller-manager` Deployment/Service
- `ks-console` Deployment/Service

这就是后续 webhook 报错的根源之一：有 webhook 规则，但没有对应 Service。

## 四、本地配置文件（必做）

本地 `kubesphere.yaml` 至少应包含：

```yaml
authentication:
  jwtSecret: "development-jwt-secret"
  multipleLogin: true
  oauthOptions:
    clients:
      - name: kubesphere
        secret: kubesphere
        redirectURIs:
          - "*"

kubernetes:
  kubeconfig: "/home/vscode/.kube/config"

monitoring:
  endpoint: "http://127.0.0.1:9090"
```

## 五、构建与启动本地后端

## 1) 构建

```bash
make ks-apiserver
make ks-controller-manager
```

产物路径：

- `bin/cmd/ks-apiserver`
- `bin/cmd/controller-manager`

## 2) 启动

```bash
mkdir -p _output/run

nohup ./bin/cmd/ks-apiserver > _output/run/ks-apiserver.log 2>&1 & echo $! > _output/run/ks-apiserver.pid
nohup ./bin/cmd/controller-manager > _output/run/controller-manager.log 2>&1 & echo $! > _output/run/controller-manager.pid
```

## 3) 运行状态检查

```bash
ps -p $(cat _output/run/ks-apiserver.pid) -o pid=,stat=,cmd=
ps -p $(cat _output/run/controller-manager.pid) -o pid=,stat=,cmd=
ss -lntp | grep -E ':9090|:8443|:8080'
```

预期：

- `ks-apiserver` 监听 `9090`
- `controller-manager` 监听 `8443`、`8080`

## 六、webhook 依赖与处理（重点）

如果你使用 filtered 资源但没有部署 `ks-controller-manager` Service，用户相关请求可能报：

- `failed calling webhook ... service "ks-controller-manager" not found`

开发联调下的临时解法（已验证）：

```bash
kubectl patch validatingwebhookconfiguration users.iam.kubesphere.io \
  --type='json' \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

校验：

```bash
kubectl get validatingwebhookconfiguration users.iam.kubesphere.io -o jsonpath='{.webhooks[0].failurePolicy}{"\n"}'
```

注意：这只是开发降级，生产环境应恢复 `Fail` 并补齐标准 Service/Deployment。

## 七、登录与前端联调校验

## 1) 后端 token 校验

```bash
curl -sS -i -X POST 'http://127.0.0.1:9090/oauth/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data 'grant_type=password&client_id=kubesphere&client_secret=kubesphere&username=admin&password=P%4088w0rd'
```

预期：HTTP `200`，返回 `access_token`。

## 2) 前端配置

- API 地址：`http://<本机IP>:9090`（容器场景可用 `http://host.docker.internal:9090`）。
- 登录请求必须携带：
  - `grant_type=password`
  - `client_id=kubesphere`
  - `client_secret=kubesphere`

## 八、停止与排障

## 1) 停止服务

```bash
kill $(cat _output/run/ks-apiserver.pid)
kill $(cat _output/run/controller-manager.pid)
```

## 2) 日志排查

```bash
tail -n 100 _output/run/ks-apiserver.log
tail -n 100 _output/run/controller-manager.log
```
