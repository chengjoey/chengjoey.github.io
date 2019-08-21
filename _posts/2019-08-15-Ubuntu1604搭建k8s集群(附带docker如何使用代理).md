---
layout: post
title:  "Ubuntu1604搭建k8s集群(附带docker如何使用代理)"
description:
date:   2019-08-15 09:30:40 +0530
categories: ubuntu k8s shadowsocks
---

本文将介绍如何在Ubuntu server 16.04版本上安装kubeadm，使用代理下载镜像, 并利用kubeadm快速的在Ubuntu server版本16.04上构建一个kubernetes的基础的测试集群，用来做学习和测试用途, 参考文档k8s官方的[kubeadm官方概述](https://kubernetes.io/zh/docs/reference/setup-tools/kubeadm/kubeadm/).

# 安装Kubenetes的先决条件
本次集群创建至少2台服务器或虚拟机, 每台服务器建议4G内存，2个CPU核心以上, 基本架构为1台master节点和1台slave节点. 整个安装过程将在Ubuntu服务器上安装完kubeadm, kubelet, kubectl, 以及安装kubenetes的基本集群, 所有的服务器都已安装docker, 还没安装的可以参考[How To Install and Use Docker on Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-16-04). 由于gcr.io 及k8s.gcr.io容器仓库的镜像代理服务需要翻墙, 本文前面大部分都是关于Ubuntu服务器如何翻墙, 翻墙的话还需要准备有翻墙服务器. 本次2个节点信息如下:

角色         | 主机名         | IP地址
:-----------: | :-----------: | :-----------:
master       | ecs-682a-0006 | 192.168.1.38
slave        | ecs-682a-0004 | 192.168.1.42



## kubeadm kubelet kubectl简单概述
- **kubeadm**: 用于初始化k8s cluster
- **kubelet**: 运行在cluster所有节点上,负责启动POD和容器
- **kubectl**: kubenetes命令行工具，通过kubectl可以部署和管理应用，查看各种资源，创建，删除和更新组件

**以下两种安装kubeadm的方式按照自身需要选择一种即可**

## 更换源使用国内镜像安装kubeadm kubelet kubectl
替换为阿里的源:
```
$cat /etc/apt/sources.list
deb http://mirrors.aliyun.com/ubuntu/ xenial main restricted
deb http://mirrors.aliyun.com/ubuntu/ xenial-updates main restricted
deb http://mirrors.aliyun.com/ubuntu/ xenial universe
deb http://mirrors.aliyun.com/ubuntu/ xenial-updates universe
deb http://mirrors.aliyun.com/ubuntu/ xenial multiverse
deb http://mirrors.aliyun.com/ubuntu/ xenial-updates multiverse
deb http://mirrors.aliyun.com/ubuntu/ xenial-backports main restricted universe multiverse
# kubeadm及kubernetes组件安装源
deb https://mirrors.aliyun.com/kubernetes/apt kubernetes-xenial main
```
添加apt-key:
```
curl -s https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add -
```
更新源:
```
sudo apt-get update
```
安装kubeadm，kubectl，kubelet软件包:
```
apt-get install -y kubelet kubeadm kubectl
```
用kubeadm version查看版本信息:
```
kubeadm version: &version.Info{Major:"1", Minor:"15", GitVersion:"v1.15.2", GitCommit:"f6278300bebbb750328ac16ee6dd3aa7d3549568", GitTreeState:"clean", BuildDate:"2019-08-05T09:20:51Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
```

## 翻墙使用代理安装kubeadm kubelet kubectl
安装shadowsocks 客户端:
```
pip install shadowsocks
```
在任一目录下新建一个配置文件,比如在/opt/shadowsocks-client下新建配置文件:conf.json
里面输入:
```
{
  "server":"my_server_ip",
  "local_address": "127.0.0.1",
  "local_port":1080,
  "server_port":my_server_port,
  "password":"my_password",
  "timeout":300,
  "method":"aes-256-cfb"
}
```
- my_server_ip改为自己的服务器IP
- my_server_port改为自己的服务器端口
- my_server_password改为自己的密码
- method的值改为自己的加密方式，一般是aes-256-cfb或者rc4-md5

后端启动:
```
sslocal -c /opt/shadowsocks-client/shadowsocks.json -d start
```
安装privoxy将socks转http代理:
```
sudo apt-get install privoxy
```
更改privoxy配置,位置在/etc/privoxy/config:
```
# 在 froward-socks4下面添加一条socks5的，因为shadowsocks为socks5，
# 地址是127.0.0.1:1080。注意他们最后有一个“.”
#        forward-socks4   /               socks-gw.example.com:1080  .
forward-socks5   /               127.0.0.1:1081 .

# 下面还存在以下一条配置，表示privoxy监听本机8118端口，
# 把它作为http代理，代理地址为 http://localhost.8118/ 。
# 可以把地址改为 0.0.0.0:8118，表示外网也可以通过本机IP作http代理。
# 这样，你的外网IP为1.2.3.4，别人就可以设置 http://1.2.3.4:8118/ 为http代理。
listen-address 127.0.0.1:1081
```
重启privoxy:
```
sudo systemctl restart privoxy.serivce
```
翻墙代理搭建完毕, 下面为使用别名方便开启和关闭的方法, vim ~/.bashrc, 在alias那里添加:
```
alias proxyon="export http_proxy='http://YOURPROXY:YOURPORT';export https_proxy='http://YOURPROXY:YOURPORT'"
alias proxyoff="export http_proxy='';export https_proxy=''"
```
source ~/.bashrc, 然后proxyon就可以开启代理, proxyoff关闭代理, 开启的情况下测试:
```
curl www.google.com
```
代理成功的话将成功返回

安装kubeadm kubectl kubelet:
```
apt-get update && apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
apt-get update
apt-get install -y kubelet kubeadm kubectl
```
用kubeadm version查看版本信息:
```
kubeadm version: &version.Info{Major:"1", Minor:"15", GitVersion:"v1.15.2", GitCommit:"f6278300bebbb750328ac16ee6dd3aa7d3549568", GitTreeState:"clean", BuildDate:"2019-08-05T09:20:51Z", GoVersion:"go1.12.5", Compiler:"gc", Platform:"linux/amd64"}
```

## 设置docker使用代理下载容器镜像
在首次用kubeadm初始化主节点时, 需要从gcr下载镜像容器, 而访问gcr需要翻墙, 所以必须设置docker使其使用代理, 如果实在翻墙不方便, 也可以用国内导出的镜像源, 为了一劳永逸的解决这个问题, 本文将使用代理.

这里使用的ip地址和端口就是前面用privoxy设置的地址和端口, 像前面设置的ip为127.0.0.1, port为1081

先新建目录如果没有的话:
```
sudo mkdir -p /etc/systemd/system/docker.service.d
```
http 代理:
```
vim /etc/systemd/system/docker.service.d/http-proxy.conf 输入:
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:1081/" "NO_PROXY=localhost,127.0.0.1,https://dockerhub.azk8s.cn"
```
https 代理, **这里需要特别注意的是HTTPS_PROXY的值不要像官方里写的用https, 而还是应该用http, 如果用HTTPs, 将会报net/http: TLS handshake timeout”的错误**:
```
vim /etc/systemd/system/docker.service.d/https-proxy.conf
[Service]
Environment="HTTPS_PROXY=http://127.0.0.1:1081/" "NO_PROXY=localhost,127.0.0.1,https://dockerhub.azk8s.cn"
```
重启docker:
```
sudo systemctl daemon-reload
sudo systemctl restart docker
```
docker info | grep -i proxy 可以看到docker 使用代理的信息:

![docker info](/images/docker-info.jpg)

## 使用kubeadmin初始化master节点
关闭所有交换设备:
```
sudo swapoff -a
```
在能够访问gcr站点后, 整个安装其实很简单, 第一次将会下载镜像容器, 也可以用kubeadm config pull提前下载:
```
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=192.168.1.38 --node-name=ecs-682a-0006
```
需要注意的是, 我指定了节点名称(--node-name), 这里需要/etc/hosts文件配置正确, 可以参考我的配置:
```
127.0.0.1 localhost ecs-682a-0006
192.168.1.38 ecs-682a-0006
# The following lines are desirable for IPv6 capable hosts
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
```
输出:
```
W0819 19:34:58.198474    8264 version.go:98] could not fetch a Kubernetes version from the internet: unable to get URL "https://dl.k8s.io/release/stable-1.txt": Get https://dl.k8s.io/release/stable-1.txt: net/http: request canceled while waiting for connection (Client.Timeout exceeded while awaiting headers)
W0819 19:34:58.198546    8264 version.go:99] falling back to the local client version: v1.15.2
[init] Using Kubernetes version: v1.15.2
[preflight] Running pre-flight checks
	[WARNING IsDockerSystemdCheck]: detected "cgroupfs" as the Docker cgroup driver. The recommended driver is "systemd". Please follow the guide at https://kubernetes.io/docs/setup/cri/
	[WARNING SystemVerification]: this Docker version is not on the list of validated versions: 19.03.1. Latest validated version: 18.09
[preflight] Pulling images required for setting up a Kubernetes cluster
[preflight] This might take a minute or two, depending on the speed of your internet connection
[preflight] You can also perform this action in beforehand using 'kubeadm config images pull'
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Activating the kubelet service
[certs] Using certificateDir folder "/etc/kubernetes/pki"
[certs] Generating "etcd/ca" certificate and key
[certs] Generating "etcd/peer" certificate and key
[certs] etcd/peer serving cert is signed for DNS names [ecs-682a-0006 localhost] and IPs [192.168.1.38 127.0.0.1 ::1]
[certs] Generating "etcd/healthcheck-client" certificate and key
[certs] Generating "apiserver-etcd-client" certificate and key
[certs] Generating "etcd/server" certificate and key
[certs] etcd/server serving cert is signed for DNS names [ecs-682a-0006 localhost] and IPs [192.168.1.38 127.0.0.1 ::1]
[certs] Generating "ca" certificate and key
[certs] Generating "apiserver" certificate and key
[certs] apiserver serving cert is signed for DNS names [ecs-682a-0006 kubernetes kubernetes.default kubernetes.default.svc kubernetes.default.svc.cluster.local] and IPs [10.96.0.1 192.168.1.38]
[certs] Generating "apiserver-kubelet-client" certificate and key
[certs] Generating "front-proxy-ca" certificate and key
[certs] Generating "front-proxy-client" certificate and key
[certs] Generating "sa" key and public key
[kubeconfig] Using kubeconfig folder "/etc/kubernetes"
[kubeconfig] Writing "admin.conf" kubeconfig file
[kubeconfig] Writing "kubelet.conf" kubeconfig file
[kubeconfig] Writing "controller-manager.conf" kubeconfig file
[kubeconfig] Writing "scheduler.conf" kubeconfig file
[control-plane] Using manifest folder "/etc/kubernetes/manifests"
[control-plane] Creating static Pod manifest for "kube-apiserver"
[control-plane] Creating static Pod manifest for "kube-controller-manager"
[control-plane] Creating static Pod manifest for "kube-scheduler"
[etcd] Creating static Pod manifest for local etcd in "/etc/kubernetes/manifests"
[wait-control-plane] Waiting for the kubelet to boot up the control plane as static Pods from directory "/etc/kubernetes/manifests". This can take up to 4m0s
[apiclient] All control plane components are healthy after 23.501899 seconds
[upload-config] Storing the configuration used in ConfigMap "kubeadm-config" in the "kube-system" Namespace
[kubelet] Creating a ConfigMap "kubelet-config-1.15" in namespace kube-system with the configuration for the kubelets in the cluster
[upload-certs] Skipping phase. Please see --upload-certs
[mark-control-plane] Marking the node ecs-682a-0006 as control-plane by adding the label "node-role.kubernetes.io/master=''"
[mark-control-plane] Marking the node ecs-682a-0006 as control-plane by adding the taints [node-role.kubernetes.io/master:NoSchedule]
[bootstrap-token] Using token: tocral.xfs96g940qu2wbf2
[bootstrap-token] Configuring bootstrap tokens, cluster-info ConfigMap, RBAC Roles
[bootstrap-token] configured RBAC rules to allow Node Bootstrap tokens to post CSRs in order for nodes to get long term certificate credentials
[bootstrap-token] configured RBAC rules to allow the csrapprover controller automatically approve CSRs from a Node Bootstrap Token
[bootstrap-token] configured RBAC rules to allow certificate rotation for all node client certificates in the cluster
[bootstrap-token] Creating the "cluster-info" ConfigMap in the "kube-public" namespace
[addons] Applied essential addon: CoreDNS
[addons] Applied essential addon: kube-proxy

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.1.38:6443 --token tocral.xfs96g940qu2wbf2 \
    --discovery-token-ca-cert-hash sha256:ee20b275ff5347c5702917a7f63ce037526228f216aa673ad0746fc4b563ca9f 
```
执行输出里的命令来配置kubectl:
```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```
使用kubectl查看节点信息, 可以看到主节点初始化完毕, kubectl get nodes:

![查看所有节点](/images/k8s-getnodes-1.png)

## 安装网络插件 Canal
在上面安装完成后会看到这样一段话:"You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/"
提示我们需要安装网络插件了, [官方文档](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#installing-a-pod-network)里有很多种可以选择,
安装 Canal:
```
kubectl apply -f https://docs.projectcalico.org/v3.8/manifests/canal.yaml
```
## Slave节点加入集群
执行如下命令, 将slave节点加入集群:
```
kubeadm join 192.168.1.38:6443 --token tocral.xfs96g940qu2wbf2 \
    --discovery-token-ca-cert-hash sha256:ee20b275ff5347c5702917a7f63ce037526228f216aa673ad0746fc4b563ca9f 
```
正常情况下, 输出如下:
```
[preflight] Running pre-flight checks
	[WARNING IsDockerSystemdCheck]: detected "cgroupfs" as the Docker cgroup driver. The recommended driver is "systemd". Please follow the guide at https://kubernetes.io/docs/setup/cri/
	[WARNING SystemVerification]: this Docker version is not on the list of validated versions: 19.03.1. Latest validated version: 18.09
[preflight] Reading configuration from the cluster...
[preflight] FYI: You can look at this config file with 'kubectl -n kube-system get cm kubeadm-config -oyaml'
[kubelet-start] Downloading configuration for the kubelet from the "kubelet-config-1.15" ConfigMap in the kube-system namespace
[kubelet-start] Writing kubelet configuration to file "/var/lib/kubelet/config.yaml"
[kubelet-start] Writing kubelet environment file with flags to file "/var/lib/kubelet/kubeadm-flags.env"
[kubelet-start] Activating the kubelet service
[kubelet-start] Waiting for the kubelet to perform the TLS Bootstrap...

This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.

Run 'kubectl get nodes' on the control-plane to see this node join the cluster.
```
等节点加入完毕, 在主节点查看:

![查看所有节点](/images/k8s-getnodes-2.png)

kubectl get pod -n kube-system -o wide:

![查看pods](/images/k8s-getpods-1.jpg)

整个k8s集群已经搭建成功, 如有疑问点击主页的github给我留言

## 遇到的问题记录
- couldn't validate the identity of the API Server: abort connecting to API servers after timeout of 5m0s

![kubeadm join miss config.yaml](/images/error1.jpg)

![kubeadm join 卡住](/images/error2.jpg)
解决方法是在主节点创建token时, 命令改为:
```
kubeadm token create --print-join-command
```

## 常用命令
- 列出具有磁盘压力的节点, pod被驱逐或者无法执行任务可能是因为磁盘压力太大, 默认不能超过85%的使用率
![被驱逐pod](/images/be-ecvited.jpg)
![磁盘使用率](/images/disk-pressure.jpg)
```
kubectl get no -ojson | jq -r '.items[] | select(.status.conditions[] | select(.status == "True") | select(.type == "DiskPressure")) | .metadata.name'
```