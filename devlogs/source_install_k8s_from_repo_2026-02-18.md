# KubeSphere 后端源码安装记录（2026-02-18）

## 目标

- 使用当前仓库源码构建并部署 `ks-apiserver`、`ks-controller-manager` 到 Kubernetes。
- 使用 Helm 安装 `ks-core`，并验证后端服务可用。
- 修复构建后 `gitVersion` 丢失问题，后端版本固定为 `v3.4.1`。
- `ks-console` 不作为本次交付范围，后续通过其他途径单独部署。

## 环境信息

- 仓库路径：`/IdeaProjects/kubesphere`
- Kubernetes 上下文：`kind-kind-1.23`
- Kubernetes 版本：`v1.23.17`
- 节点：`kind-1.23-control-plane`
- 工具版本：
  - `docker 29.2.1`
  - `docker buildx v0.31.1`
  - `helm v3.15.4`
  - `kubectl v1.23.17`

## 范围边界

- 本次纳入：`ks-apiserver`、`ks-controller-manager` 的源码构建与集群运行验证。
- 本次不纳入：`ks-console` 的前端构建、登录验证、功能点回归。
- 后续安排：`ks-console` 将在前端工程或独立流程中单独部署。

## 安装步骤

### 1) 构建源码镜像

使用统一标签，并显式注入后端版本号：

```bash
export TAG=dev-20260218-v3.4.1
export KUBE_GIT_VERSION=v3.4.1
export KUBE_GIT_MAJOR=3
export KUBE_GIT_MINOR=4
export KUBE_GIT_TREE_STATE=clean
```

先编译后端二进制：

```bash
make ks-apiserver
make ks-controller-manager
```

说明：当前分支构建时若不显式设置 `KUBE_GIT_VERSION`，会因 `git describe --tags --match='v*'` 失败导致 `gitVersion` 回退为默认值 `v0.0.0`。  
本次使用“源码二进制 + 本地镜像重打包”方式生成新镜像，避免版本信息丢失，并减少对外网基础镜像拉取的依赖：

```bash
cat > /tmp/Dockerfile.ks-apiserver.repack <<'EOF'
FROM kubesphere/ks-apiserver:dev-20260218

COPY bin/cmd/ks-apiserver /usr/local/bin/ks-apiserver
EOF

cat > /tmp/Dockerfile.ks-controller-manager.repack <<'EOF'
FROM kubesphere/ks-controller-manager:dev-20260218

COPY bin/cmd/controller-manager /usr/local/bin/controller-manager
EOF

docker build -f /tmp/Dockerfile.ks-apiserver.repack \
  -t kubesphere/ks-apiserver:${TAG} .
docker build -f /tmp/Dockerfile.ks-controller-manager.repack \
  -t kubesphere/ks-controller-manager:${TAG} .
```

### 2) 将源码镜像导入 Kind 节点

当前环境未安装 `kind` CLI，使用 `docker save | ctr import` 导入：

```bash
docker save kubesphere/ks-apiserver:${TAG} \
  | docker exec -i kind-1.23-control-plane ctr -n k8s.io images import -

docker save kubesphere/ks-controller-manager:${TAG} \
  | docker exec -i kind-1.23-control-plane ctr -n k8s.io images import -
```

### 3) Helm 安装 ks-core（覆盖后端镜像）

```bash
kubectl create namespace kubesphere-controls-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install ks-core ./config/ks-core -n kubesphere-system --create-namespace \
  --set image.ks_apiserver_repo=kubesphere/ks-apiserver \
  --set image.ks_apiserver_tag=${TAG} \
  --set image.ks_controller_manager_repo=kubesphere/ks-controller-manager \
  --set image.ks_controller_manager_tag=${TAG} \
  --set image.pullPolicy=IfNotPresent
```

说明：chart 默认同时部署 `ks-console`，且默认镜像 `kubesphere/ks-console:v3.2.1` 不可拉取。为保证 `ks-core` release 可安装并完成后端验证，本次临时切换为可用镜像：

```bash
helm upgrade ks-core ./config/ks-core -n kubesphere-system \
  --set image.ks_apiserver_repo=kubesphere/ks-apiserver \
  --set image.ks_apiserver_tag=${TAG} \
  --set image.ks_controller_manager_repo=kubesphere/ks-controller-manager \
  --set image.ks_controller_manager_tag=${TAG} \
  --set image.ks_console_repo=kubespheredev/ks-console \
  --set image.ks_console_tag=v3.2.1 \
  --set image.pullPolicy=IfNotPresent
```

该 `ks-console` 镜像仅用于本次环境兼容，不作为后续正式 console 部署方案。

## 验证结果（后端验收）

### 1) Deployment 就绪

```bash
kubectl -n kubesphere-system rollout status deploy/ks-apiserver --timeout=5m
kubectl -n kubesphere-system rollout status deploy/ks-controller-manager --timeout=5m
```

结果：两个后端 Deployment 均 `successfully rolled out`。  
补充：当前环境下 `ks-console` 也为 `Running`，但不作为本次验收项。

### 2) 实际运行镜像

```bash
kubectl -n kubesphere-system get deploy -o wide
```

关键结果：

- `ks-apiserver`：`kubesphere/ks-apiserver:dev-20260218-v3.4.1`（源码镜像）
- `ks-controller-manager`：`kubesphere/ks-controller-manager:dev-20260218-v3.4.1`（源码镜像）

### 3) Pod 与 Service 状态

```bash
kubectl -n kubesphere-system get pods -o wide
kubectl -n kubesphere-system get svc -o wide
```

结果：`kubesphere-system` 核心 Pod 运行正常，后端 Service 可用。

### 4) API 连通性

通过端口转发验证 `ks-apiserver`：

```bash
kubectl -n kubesphere-system port-forward svc/ks-apiserver 19090:80
curl -fsS http://127.0.0.1:19090/kapis/version
```

结果：返回版本 JSON，关键字段如下：

- `gitVersion: v3.4.1`
- `gitMajor: 3`
- `gitMinor: 4`
- `gitCommit: 9d8623d163573c27a18b48bfb1231bdc9913b2d1`
- `gitTreeState: clean`

## 未执行项

- `make vet`、`make test`（本次任务聚焦部署验证，未做代码质量/单测全量回归）。
- `ks-console` 页面登录与功能点手工回归（本次明确不纳入）。

## 已知差异与说明

- 本仓库当前不存在 `config/crds` 目录，直接使用 chart 自带 `config/ks-core/crds`。
- 当前工作副本中 `git describe --tags --match='v*'` 无法得到可用版本描述，默认构建会出现 `gitVersion=v0.0.0`。
- 本次通过显式设置 `KUBE_GIT_VERSION=v3.4.1`（及 `KUBE_GIT_MAJOR`、`KUBE_GIT_MINOR`）修复版本注入。
- 为降低网络依赖并规避 `build/ks-controller-manager/Dockerfile` 的 `apk` 在线安装问题，本次使用“已构建镜像为 base + 覆盖二进制”的重打包方式。
- `kind` CLI 未安装，改用 `ctr import` 导入镜像。
- chart 默认 `ks-console` 镜像不可拉取，本次用 `kubespheredev/ks-console:v3.2.1` 做临时兼容。

## 后续待办（Console 另行部署）

1. 在前端工程或独立流程完成 `ks-console` 镜像构建与发布。
2. 使用正式镜像更新 `ks-core` 中 `ks-console` 部署（`helm upgrade ... --set image.ks_console_repo=... --set image.ks_console_tag=...`）。
3. 执行 `ks-console` 登录与关键功能回归测试。

## 卸载命令

```bash
helm uninstall ks-core -n kubesphere-system
kubectl delete namespace kubesphere-system
kubectl delete namespace kubesphere-controls-system
```
