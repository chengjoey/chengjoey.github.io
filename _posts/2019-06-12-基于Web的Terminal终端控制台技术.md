---
layout: post
title:  "基于Web的Terminal终端控制台"
description:
date:   2019-06-12 20:30:40 +0530
categories: golang xterm vue websocket
---

这篇博客将描述一下我如何用golang和vue实现一个简易的网页版xshell. **[github 项目地址](https://github.com/chengjoey/web-terminal)**.
完成这样一个Web Terminal的目的主要是解决几个问题:
- 一定程度上取代xshell，secureRT，putty等ssh终端
- 可以方便身份认证, 访问控制
- 方便使用, 不受电脑环境的影响

**[演示地址](http://101.91.122.2:5001/)**

要实现远程登陆的功能, 其数据流向大概为:
```
浏览器<--->WebSocket<--->SSH<--->Linux OS
```

要具体实现的话流程大概为:
1. 浏览器将主机的信息(ip, 用户名, 密码, 请求的终端大小等)进行加密, 传给后台, 并通过HTTP请求与后台协商升级协议. 协议升级完成后, 后续的数据交换则遵照web Socket的协议.
2. 后台将HTTP请求升级为web Socket协议, 得到一个和浏览器数据交换的连接通道
3. 后台将数据进行解密拿到主机信息, 创建一个SSH 客户端, 与远程主机的SSH 服务端协商加密, 互相认证, 然后建立一个SSH Channel
4. 后台和远程主机有了通讯的信道, 然后后台将终端的大小等信息通过SSH Channel请求远程主机创建一个 pty(伪终端), 并请求启动当前用户的默认 shell
5. 后台通过 Socket连接通道拿到用户输入, 再通过SSH Channel将输入传给pty, pty将这些数据交给远程主机处理后按照前面指定的终端标准输出到SSH Channel中, 同时键盘输入也会发送给SSH Channel
6. 后台从SSH Channel中拿到按照终端大小的标准输出后又通过Socket连接将输出返回给浏览器, 由此变实现了Web Terminal

登陆截图

![登陆截图](/images/web-terminal-demo1.jpg)

连接成功截图

![连接成功截图](/images/web-terminal-demo2.jpg)

## WebSocket
**WebSocket**是HTML5开始提供的一种浏览器与服务器进行全双工通讯的网络技术，属于应用层协议。它基于TCP传输协议，并复用HTTP的握手通道。[详细websocket介绍](https://segmentfault.com/a/1190000012709475)

以下按照上面的流程并基于代码解释如何实现(只讲解关键代码, 具体可以clone项目, 里面有注释).

## 升级HTTP协议为web Socket
定义常量, 升级器:
```
var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true
	},
}
```
升级协议并获得socket连接:
```
conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
if err != nil {
    c.Error(err)
    return
}
```
**conn**就是socket连接通道, 接下来后台和浏览器之间的通讯都将基于这个通道

## 后台拿到主机信息, 建立ssh 客户端
ssh 客户端结构体:
```
type SSHClient struct {
	Username  string `json:"username"`
	Password  string `json:"password"`
	IpAddress string `json:"ipaddress"`
	Port      int    `json:"port"`
	Session   *ssh.Session
	Client    *ssh.Client
	channel   ssh.Channel
}

//创建新的ssh客户端时, 默认用户名为root, 端口为22
func NewSSHClient() SSHClient {
	client := SSHClient{}
	client.Username = "root"
	client.Port = 22
	return client
}
```
初始化的时候我们只有主机的信息, 而Session, client, channel都是空的, 现在先生成真正的client:
```
func (this *SSHClient) GenerateClient() error {
	var (
		auth         []ssh.AuthMethod
		addr         string
		clientConfig *ssh.ClientConfig
		client       *ssh.Client
		config       ssh.Config
		err          error
	)
	auth = make([]ssh.AuthMethod, 0)
	auth = append(auth, ssh.Password(this.Password))
	config = ssh.Config{
		Ciphers: []string{"aes128-ctr", "aes192-ctr", "aes256-ctr", "aes128-gcm@openssh.com", "arcfour256", "arcfour128", "aes128-cbc", "3des-cbc", "aes192-cbc", "aes256-cbc"},
	}
	clientConfig = &ssh.ClientConfig{
		User:    this.Username,
		Auth:    auth,
		Timeout: 5 * time.Second,
		Config:  config,
		HostKeyCallback: func(hostname string, remote net.Addr, key ssh.PublicKey) error {
			return nil
		},
	}
	addr = fmt.Sprintf("%s:%d", this.IpAddress, this.Port)
	if client, err = ssh.Dial("tcp", addr, clientConfig); err != nil {
		return err
	}
	this.Client = client
	return nil
}
```
ssh.Dial("tcp", addr, clientConfig)创建连接并返回客户端, 如果主机信息不对或其它问题这里将直接失败

## 通过ssh 客户端创建ssh channel, 并请求一个pty伪终端, 请求用户的默认会话
如果主机信息验证通过, 可以通过ssh client创建一个通道:
```
channel, inRequests, err := this.Client.OpenChannel("session", nil)
if err != nil {
    log.Println(err)
    return nil
}
this.channel = channel
```
ssh通道创建完成后, 请求一个标准输出的终端, 并开启用户的默认shell:
```
ok, err := channel.SendRequest("pty-req", true, ssh.Marshal(&req))
if !ok || err != nil {
    log.Println(err)
    return nil
}
ok, err = channel.SendRequest("shell", true, nil)
if !ok || err != nil {
    log.Println(err)
    return nil
}
```

## 远程主机与浏览器实时数据交换
现在为止建立了两个通道, 一个是websocket, 一个是ssh channel, 后台将起两个主要的协程, 一个不停的从websocket通道里读取用户的输入, 并通过ssh channel传给远程主机:
```
//这里第一个协程获取用户的输入
go func() {
    for {
        // p为用户输入
        _, p, err := ws.ReadMessage()
        if err != nil {
            return
        }
        _, err = this.channel.Write(p)
        if err != nil {
            return
        }
    }
}()
```
第二个主协程将远程主机的数据传递给浏览器, 在这个协程里还将起一个协程, 不断获取ssh channel里的数据并传给后台内部创建的一个通道, 主协程则有一个死循环, 每隔一段时间从内部通道里读取数据, 并将其通过websocket传给浏览器, 所以数据传输并不是真正实时的,而是有一个间隔在, 我写的默认为100微秒, 这样基本感受不到延迟, 而且减少了消耗, 有时浏览器输入一个命令获取大量数据时, 会感觉数据出现会一顿一顿的便是因为设置了一个间隔:
```
//第二个协程将远程主机的返回结果返回给用户
go func() {
    br := bufio.NewReader(this.channel)
    buf := []byte{}
    t := time.NewTimer(time.Microsecond * 100)
    defer t.Stop()
    // 构建一个信道, 一端将数据远程主机的数据写入, 一段读取数据写入ws
    r := make(chan rune)

    // 另起一个协程, 一个死循环不断的读取ssh channel的数据, 并传给r信道直到连接断开
    go func() {
        defer this.Client.Close()
        defer this.Session.Close()

        for {
            x, size, err := br.ReadRune()
            if err != nil {
                log.Println(err)
                ws.WriteMessage(1, []byte("\033[31m已经关闭连接!\033[0m"))
                ws.Close()
                return
            }
            if size > 0 {
                r <- x
            }
        }
    }()

    // 主循环
    for {
        select {
        // 每隔100微秒, 只要buf的长度不为0就将数据写入ws, 并重置时间和buf
        case <-t.C:
            if len(buf) != 0 {
                err := ws.WriteMessage(websocket.TextMessage, buf)
                buf = []byte{}
                if err != nil {
                    log.Println(err)
                    return
                }
            }
            t.Reset(time.Microsecond * 100)
        // 前面已经将ssh channel里读取的数据写入创建的通道r, 这里读取数据, 不断增加buf的长度, 在设定的 100 microsecond后由上面判定长度是否返送数据
        case d := <-r:
            if d != utf8.RuneError {
                p := make([]byte, utf8.RuneLen(d))
                utf8.EncodeRune(p, d)
                buf = append(buf, p...)
            } else {
                buf = append(buf, []byte("@")...)
            }
        }
    }
}()
```
web terminal的后台变建立好了.

## 前端
前端我选择用了vue框架(其实这么小的项目完全不用vue), 终端工具用的是xterm, vscode内置的终端也是采用的xterm.这里贴一段关键代码, **[前端项目地址](https://github.com/chengjoey/web-terminal-client)**
```
mounted () {
    var containerWidth = window.screen.height;
    var containerHeight = window.screen.width;
    var cols = Math.floor((containerWidth - 30) / 9);
    var rows = Math.floor(window.innerHeight/17) - 2;
    if (this.username === undefined){
        var url = (location.protocol === "http:" ? "ws" : "wss") + "://" + location.hostname + ":5001" + "/ws"+ "?" + "msg=" + this.msg + "&rows=" + rows + "&cols=" + cols;
    }else{
        var url = (location.protocol === "http:" ? "ws" : "wss") + "://" + location.hostname + ":5001" + "/ws"+ "?" + "msg=" + this.msg + "&rows=" + rows + "&cols=" + cols + "&username=" + this.username + "&password=" + this.password;
    }
    let terminalContainer = document.getElementById('terminal')
    this.term = new Terminal()
    this.term.open(terminalContainer)
    // open websocket
    this.terminalSocket = new WebSocket(url)
    this.terminalSocket.onopen = this.runRealTerminal
    this.terminalSocket.onclose = this.closeRealTerminal
    this.terminalSocket.onerror = this.errorRealTerminal
    this.term.attach(this.terminalSocket)
    this.term._initialized = true
    console.log('mounted is going on')
}
```

如果由问题可以项目地址到[GitHub](https://github.com/chengjoey/web-terminal)给我留言