# KubeSphere Gateway 部署与测试（成功步骤）

## 目标

- 在当前仓库中部署可用的 Gateway（ingress-nginx）。
- 让 KubeSphere 页面创建的路由可直接生效。
- 给出可复现的测试命令与验收标准。

## 环境前提

- 仓库路径：`/IdeaProjects/kubesphere`
- Kubernetes 上下文可用：`kubectl config current-context`
- 已安装：`kubectl`、`helm`

## 部署步骤（成功路径）

### 1) 安装/升级 Gateway ingress controller

```bash
helm upgrade --install kubesphere-router-ingress ./_output/local-ingress-nginx/ingress-nginx \
  -n kubesphere-controls-system \
  --create-namespace \
  --set controller.image.repository=registry.k8s.io/ingress-nginx/controller \
  --set controller.image.tag=v1.3.1 \
  --set-string controller.image.digest= \
  --set controller.service.type=NodePort \
  --set controller.admissionWebhooks.enabled=false \
  --set controller.watchIngressWithoutClass=true \
  --wait --timeout 5m
```

### 2) 验证 release 与工作负载

```bash
helm -n kubesphere-controls-system status kubesphere-router-ingress
kubectl -n kubesphere-controls-system get pods -l app.kubernetes.io/name=ingress-nginx -o wide
kubectl -n kubesphere-controls-system get svc -l app.kubernetes.io/name=ingress-nginx -o wide
```

验收点：

- Helm 状态为 `deployed`
- controller Pod 为 `Running`
- Service 类型为 `NodePort`

### 3) 在 KubeSphere 页面创建路由

- 进入页面路由配置，为目标服务创建路由（示例：`kubesphere-system/ks-console`）。
- 示例规则：
  - Host：`cce.king.io`
  - Path：`/`
  - Backend Service：`ks-console:80`

创建后可用以下命令确认 Ingress 存在：

```bash
kubectl -n kubesphere-system get ingress
kubectl -n kubesphere-system get ingress cce-router -o yaml
```

## 测试步骤（成功路径）

### 1) 验证 controller 已接管页面创建的 Ingress

```bash
kubectl -n kubesphere-controls-system logs -l app.kubernetes.io/name=ingress-nginx --since=10m | \
  grep -E "Found valid IngressClass|Scheduled for sync|cce-router"
```

验收点：

- 日志出现 `Found valid IngressClass`
- 日志出现 `Scheduled for sync`

### 2) 本地端口转发验证路由转发

```bash
kubectl -n kubesphere-controls-system port-forward svc/kubesphere-router-ingress-ingress-nginx-controller 18080:80
```

新开一个终端执行：

```bash
curl -I -H 'Host: cce.king.io' http://127.0.0.1:18080/
```

验收点（示例）：

- 返回 `HTTP/1.1 302 Found`
- 响应头包含 `Location: /login`

## 常用排查命令（只读）

```bash
kubectl -n kubesphere-controls-system get deploy kubesphere-router-ingress-ingress-nginx-controller \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'

helm -n kubesphere-controls-system get values kubesphere-router-ingress
```

关键检查项：

- 参数中包含 `--watch-ingress-without-class=true`
- values 中包含 `controller.watchIngressWithoutClass: true`
