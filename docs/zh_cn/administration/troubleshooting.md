---
title: 问题排查方法
slug: /troubleshooting
sidebar_position: 6
---

阅读本章以了解如何对 JuiceFS CSI 驱动进行问题排查。不论面临何种错误，排查过程都需要你熟悉 CSI 驱动的各个组件及其作用，因此继续阅读前，请确保你已了解 [JuiceFS CSI 驱动架构](../introduction.md#architecture)。

## 基础问题排查原则 {#basic-principles}

在 JuiceFS CSI 驱动中，常见错误有两种：一种是 PV 创建失败，属于 CSI Controller 的职责；另一种是应用 Pod 创建失败，属于 CSI Node 和 Mount Pod 的职责。

### PV 创建失败

在[「动态配置」](../guide/pv.md#dynamic-provisioning)下，PVC 创建之后，CSI Controller 会同时配合 kubelet 自动创建 PV。在此期间，CSI Controller 会在 JuiceFS 文件系统中创建以 PV ID 为名的子目录（如果不希望以 PV ID 命名子目录，可以通过 [`pathPattern`](../guide/pv.md#using-path-pattern) 来调整）。

#### 查看 PVC 事件

一般而言，如果创建子目录失败，CSI Controller 会将错误结果存在 PVC 事件中：

```shell {7}
$ kubectl describe pvc dynamic-ce
...
Events:
  Type     Reason       Age                From               Message
  ----     ------       ----               ----               -------
  Normal   Scheduled    27s                default-scheduler  Successfully assigned default/juicefs-app to cluster-0003
  Warning  FailedMount  11s (x6 over 27s)  kubelet            MountVolume.SetUp failed for volume "juicefs-pv" : rpc error: code = Internal desc = Could not mount juicefs: juicefs auth error: Failed to fetch configuration for volume 'juicefs-pv', the token or volume is invalid.
```

#### 检查 CSI Controller {#check-csi-controller}

若 PVC 事件中并无错误信息，我们需要检查 CSI Controller 容器是否存活，以及是否存在异常日志：

```shell
# 检查 CSI Controller 是否存活
$ kubectl -n kube-system get po -l app=juicefs-csi-controller
NAME                       READY   STATUS    RESTARTS   AGE
juicefs-csi-controller-0   3/3     Running   0          8d

# 检查 CSI Controller 日志是否存在异常信息
$ kubectl -n kube-system logs juicefs-csi-controller-0 juicefs-plugin
```

### 应用 Pod 创建失败

在 CSI 驱动的架构下，JuiceFS 客户端运行在 Mount Pod 中。因此每一个应用 pod 都伴随着一个对应的 Mount Pod。

CSI Node 会负责创建 Mount Pod 并在其中挂载 JuiceFS 文件系统，最终将挂载点 bind 到应用 pod 内。因此如果应用 pod 创建失败，既可能是 CSI Node 的问题，也可能是 Mount Pod 的问题，需要逐一排查。

#### 查看应用 Pod 事件

若挂载期间有报错，报错信息往往出现在应用 pod 事件中：

```shell {7}
$ kubectl describe po dynamic-ce-1
...
Events:
  Type     Reason       Age               From               Message
  ----     ------       ----              ----               -------
  Normal   Scheduled    53s               default-scheduler  Successfully assigned default/ce-static-1 to ubuntu-node-2
  Warning  FailedMount  4s (x3 over 37s)  kubelet            MountVolume.SetUp failed for volume "ce-static" : rpc error: code = Internal desc = Could not mount juicefs: juicefs status 16s timed out
```

通过应用 pod 事件确认创建失败的原因与 JuiceFS 有关以后，可以按照下面的步骤逐一排查。

#### 检查 CSI Node {#check-csi-node}

首先，我们需要检查应用 pod 所在节点的 CSI Node 容器是否存活，以及是否存在异常日志：

```shell
# 提前将应用 pod 信息存为环境变量
APP_NS=default  # 应用所在的 Kubernetes 命名空间
APP_POD_NAME=example-app-xxx-xxx

# 通过应用 pod 找到节点名
NODE_NAME=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{.spec.nodeName}')

# 打印出所有 CSI Node pods
kubectl -n kube-system get po -l app=juicefs-csi-node

# 打印应用 pod 所在节点的 CSI Node pod
kubectl -n kube-system get po -l app=juicefs-csi-node --field-selector spec.nodeName=$NODE_NAME

# 将下方 $CSI_NODE_POD 替换为上一条命令获取到的 CSI Node pod 名称，检查日志，确认有无异常
kubectl -n kube-system logs $CSI_NODE_POD -c juicefs-plugin
```

或者直接用一行命令打印出应用 pod 对应的 CSI Node pod 日志（需要设置好 `APP_NS` 和 `APP_POD_NAME` 环境变量）：

```shell
kubectl -n kube-system logs $(kubectl -n kube-system get po -o jsonpath='{..metadata.name}' -l app=juicefs-csi-node --field-selector spec.nodeName=$(kubectl get po -o jsonpath='{.spec.nodeName}' -n $APP_NS $APP_POD_NAME)) -c juicefs-plugin
```

#### 检查 Mount Pod {#check-mount-pod}

如果 CSI Node 一切正常，则需要检查 Mount Pod 是否存在异常。

通过应用 pod 定位到 mount pod 的步骤稍显繁琐，因此我们准备了一系列快捷命令，帮你方便地获取信息：

```shell
# 如果情况不复杂，可以直接用下方命令打印所有 mount pod 错误日志
kubectl -n kube-system logs -l app.kubernetes.io/name=juicefs-mount | grep -v "<WARNING>" | grep -v "<INFO>"

# 提前将应用 pod 信息存为环境变量
APP_NS=default  # 应用所在的 Kubernetes 命名空间
APP_POD_NAME=example-app-xxx-xxx

# 通过应用 pod 找到节点名、PVC 名、PV 名
NODE_NAME=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{.spec.nodeName}')
# 如果应用 pod 挂载了多个 PV，以下命令将只考虑首个，请按需调整。
PVC_NAME=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{..persistentVolumeClaim.claimName}' | awk '{print $1}')
PV_NAME=$(kubectl -n $APP_NS get pvc $PVC_NAME -o jsonpath='{.spec.volumeName}')
PV_ID=$(kubectl get pv $PV_NAME -o jsonpath='{.spec.csi.volumeHandle}')

# 找到该应用 pod 对应的 mount pod 名
MOUNT_POD_NAME=$(kubectl -n kube-system get po --field-selector spec.nodeName=$NODE_NAME -l app.kubernetes.io/name=juicefs-mount -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep $PV_ID)

# 检查 mount pod 状态是否正常
kubectl -n kube-system get po $MOUNT_POD_NAME

# 打印 mount pod 事件
kubectl -n kube-system describe po $MOUNT_POD_NAME

# 打印 mount pod 日志（其中包含 JuiceFS 客户端日志）
kubectl -n kube-system logs $MOUNT_POD_NAME

# 打印 mount pod 的启动命令，这是一个较容易忽视的排查要点。
# 如果挂载选项（mountOptions）填写格式有误，则可能造成启动命令参数错误。
kubectl get pod -o jsonpath='{..containers[0].command}' $MOUNT_POD_NAME

# 找到该 PV 对应的所有 mount pod
kubectl -n kube-system get po -l app.kubernetes.io/name=juicefs-mount -o wide | grep $PV_ID
```

或者更为快捷地，直接用下方的单行命令：

```shell
# 需要设置好 APP_NS 和 APP_POD_NAME 环境变量

# 打印 mount pod 名称
kubectl -n kube-system get po --field-selector spec.nodeName=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{.spec.nodeName}') -l app.kubernetes.io/name=juicefs-mount -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep $(kubectl get pv $(kubectl -n $APP_NS get pvc $(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{..persistentVolumeClaim.claimName}' | awk '{print $1}') -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')

# 进入 mount pod 中，交互式运行命令
kubectl -n kube-system exec -it $(kubectl -n kube-system get po --field-selector spec.nodeName=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{.spec.nodeName}') -l app.kubernetes.io/name=juicefs-mount -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep $(kubectl get pv $(kubectl -n $APP_NS get pvc $(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{..persistentVolumeClaim.claimName}' | awk '{print $1}') -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.csi.volumeHandle}')) -- bash
```

### 性能问题

如果使用 CSI 驱动时，各组件均无异常，但却遇到了性能问题，则需要用到本节介绍的排查方法。

#### 查看实时统计数据以及访问日志 {#accesslog-and-stats}

JuiceFS 文件系统的根目录下有一些提供特殊功能的隐藏文件，假设挂载点为 `/jfs`：

* `cat /jfs/.accesslog` 实时打印文件系统的访问日志，用于分析应用程序对文件系统的访问模式，详见[「访问日志（社区版）」](https://juicefs.com/docs/zh/community/fault_diagnosis_and_analysis#access-log)和[「访问日志（云服务）」](https://juicefs.com/docs/zh/cloud/administration/fault_diagnosis_and_analysis#oplog)。
* `cat /jfs/.stats` 打印文件系统的实时统计数据，当 JuiceFS 性能不佳时，可以通过实时统计数据判断问题所在。详见[「实时统计数据（社区版）」](https://juicefs.com/docs/zh/community/performance_evaluation_guide/#juicefs-stats)和[「实时统计数据（云服务）」](https://juicefs.com/docs/zh/cloud/administration/fault_diagnosis_and_analysis#stats)。

Mount Pod 会将 JuiceFS 根目录挂载到形如 `/var/lib/juicefs/volume/pvc-xxx-xxx-xxx-xxx-xxx-xxx` 的目录下，再通过 Kubernetes 的 bind 机制映射到容器内，因此，对于给定应用 Pod，你可以参考下方命令，找到其 PV 的宿主机挂载点，然后查看隐藏文件：

```shell
# 提前将应用 pod 信息存为环境变量
APP_NS=default  # 应用所在的 Kubernetes 命名空间
APP_POD_NAME=example-app-xxx-xxx

# 如果应用 pod 挂载了多个 PV，以下命令将只考虑首个，请按需调整。
PVC_NAME=$(kubectl -n $APP_NS get po $APP_POD_NAME -o jsonpath='{..persistentVolumeClaim.claimName}' | awk '{print $1}')
PV_NAME=$(kubectl -n $APP_NS get pvc $PVC_NAME -o jsonpath='{.spec.volumeName}')

# 通过 PV 名查找宿主机挂载点
df -h | grep $PV_NAME

# 一行命令进入宿主机挂载点
cd $(df -h | grep $PV_NAME | awk '{print $NF}')

# 访问所需要的隐藏文件，进行相关排查
cat .accesslog
cat .stats
```

本节仅介绍如何在 CSI 驱动中定位到隐藏文件，而如何通过隐藏文件进行问题排查，是一个单独的话题，请参考以下内容：

* CSI 驱动问题排查案例：[读性能差](./troubleshooting-cases.md#bad-read-performance)
* 访问日志：[社区版](https://juicefs.com/docs/zh/community/fault_diagnosis_and_analysis#access-log)、[云服务](https://juicefs.com/docs/zh/cloud/administration/fault_diagnosis_and_analysis#oplog)
* 实时统计数据：[社区版](https://juicefs.com/docs/zh/community/performance_evaluation_guide/#juicefs-stats)、[云服务](https://juicefs.com/docs/zh/cloud/administration/fault_diagnosis_and_analysis#stats)

## 寻求帮助

如果自行排查无果，可能需要寻求社区，或者 Juicedata 团队帮助，这时需要你先行采集一些信息，帮助后续的分析排查。

### 查看 JuiceFS CSI 驱动版本

通过以下命令获取当前版本：

```shell
kubectl -n kube-system get po -l app=juicefs-csi-controller -o jsonpath='{.items[*].spec.containers[*].image}'
```

以上命令会有类似 `juicedata/juicefs-csi-driver:v0.17.1` 这样的输出，最后的 `v0.17.1` 即为 JuiceFS CSI 驱动的版本。

### 诊断脚本

你可以使用[诊断脚本](https://github.com/juicedata/juicefs-csi-driver/blob/master/scripts/diagnose.sh)来收集日志及相关信息。

在集群中任意一台可以执行 `kubectl` 的节点上，安装诊断脚本：

```shell
wget https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/master/scripts/diagnose.sh
chmod a+x diagnose.sh
```

使用诊断脚本获取应用 pod 使用的 mount pod。假设应用 pod 名为 `dynamic-ce-1`，所在 namespace 为 `default`。

```shell
$ ./diagnose.sh
Usage:
    ./diagnose.sh COMMAND [OPTIONS]
ENV:
    JUICEFS_NAMESPACE: namespace of JuiceFS CSI Driver, default is kube-system.
COMMAND:
    help
        Display this help message.
    get-mount
        Print mount pod used by specified app pod.
    get-app
        Print app pods using specified mount pod.
    collect
        Collect csi & mount pods logs of juicefs.
OPTIONS:
    -po, --pod name
        Set the name of app pod.
    -n, --namespace name
        Set the namespace of app pod, default is default.
    -m, --mount pod name
        Set the name of mount pod.

# 设置 juicefs csi driver 组件所在 namespace，默认为 kube-system
$ export JUICEFS_NAMESPACE=kube-system
# 获取指定 pod 所用的 mount pod
$ ./diagnose.sh get-mount -po dynamic-ce-1
Mount Pod which app dynamic-ce-1 using is:
namespace:
  kube-system
name:
  juicefs-ubuntu-node-2-pvc-b94bd312-f5f7-4f46-afdb-2d1bc20371b5-whrrym
```

也可以使用诊断脚本来收集信息。假设应用 pod 名为 `dynamic-ce-1`，所在 namespace 为 `default`。

```shell
# 设置 juicefs csi driver 组件所在 namespace，默认为 kube-system
$ export JUICEFS_NAMESPACE=kube-system
# 收集诊断信息
$ ./diagnose.sh collect -po dynamic-ce-1 -n default
Start collecting, pod=dynamic-ce-1, namespace=default
...
please get diagnose_juicefs_1671073110.tar.gz for diagnostics
```

所有相关的信息都被收集和打包在了一个压缩包里。

如果已知 Mount pod name，也可以使用诊断脚本获取所有使用该 mount pod 的所有应用 pod。假设已知 Mount pod 名为 `juicefs-ubuntu-node-3-pvc-b94bd312-f5f7-4f46-afdb-2d1bc20371b5-octdjc`，JuiceFS CSI 驱动的组件所在 namespace 为 `kube-system`。

```shell
# 设置 juicefs csi driver 组件所在 namespace，默认为 kube-system
$ export JUICEFS_NAMESPACE=kube-system
# 获取使用指定 mount pod 的所有应用 pod
$ ./diagnose.sh get-app -m juicefs-ubuntu-node-3-pvc-b94bd312-f5f7-4f46-afdb-2d1bc20371b5-octdjc
App pods using mount pod [juicefs-ubuntu-node-3-pvc-b94bd312-f5f7-4f46-afdb-2d1bc20371b5-octdjc]:
namespace:
  default
apps:
  dynamic-ce-5
  dynamic-ce-2
  dynamic-ce-3
  dynamic-ce-4
```