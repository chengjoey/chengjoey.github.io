---
layout: post
title:  "商家平台客户聊天系统demo"
description:
date:   2021-01-16 22:35:00 +0530
categories: Golang1.16 Redis WebSocket EventSource Gin
---
__本文目标是为了建立一个商家和客户的聊天系统demo, 当商家的管理员或客服登录系统时, 能在dashboard上看到在线的等待商家接入沟通的用户, 能点击聊天按钮实时的与客服沟通, 并且用户的离开和进入能实时的在首页进行更新, 用户登录时直接进入聊天室中, 能看到历史的聊天记录, 管理员或客服进入聊天室时能进行沟通__


演示图, 左边为管理员用户, 右边为普通用户
![效果演示图](/images/chatadmin-demo.gif)

管理员在登录到dashboard首页时, 能实时的看到用户进入离开的更新变化, 服务端会在更新时将数据推送到浏览器上, 而浏览器并不需要传输数据到服务端, 所以在首页上更新用户的地方将采用eventsource, eventsource协议也更多的用来股票行情, 消息新闻推送等. 聊天室聊天时采用的是websocket协议, 首先让我们了解一下这两种协议.

>WebSocket:
> 1. 全双工连接和新的Web Socket服务器来处理协议
> 2. 实时，双向通讯
> 3. 在更多浏览器中的本机支持
> 4. 可以同时传输二进制数据和UTF-8
> 5. 对于某些类型的应用程序来说，可能过重

启动我们的服务然后用go的websocket客户端建立链接，并尝试用wireshark进行抓包
```
go run cmd/websocket/client.go d0o3lVcL0oWmdZL0W7g/YOB3uRlfHUT+5E2DY/x2axi7Xch7KfftSstXZWTvnOC5 admin
```
![websocket抓包图](/images/websocket-wireshark.png)
在经历了tcp三次握手后，会将http协议升级为websocket， 后面的双向数据传输将用websocket进行

>EventSource
> 1. 通过简单的HTTP而不是自定义协议进行传输
> 2. 没有二进制支持
> 3. SSE连接只能将数据推送到浏览器
> 4. 最大开放连接数限制
> 5. 用postman, curl等工具就能进行调试

启动我们的服务然后用curl建立一个sse链接，并尝试用wireshark进行抓包
```
curl -v http://localhost:9090/v1/stream -H "Content-Type:text/event-stream" -H "Authorization:nzzP5vUSCTf+kuyO1V8fqSx50kx7JfQywPT4qUJhaftTxOYjlGYXHaLBmpsNGWBh
```
![sse抓包图](/images/eventsource-wireshark.png)
可以看到仍然是http协议，在经历过最初的三次握手后， 建立起http链接, 但是是一个长链接, 从头部的connection为keep-alive可以看出来

下面介绍一下我如何实现这个功能，将展示关键代码和逻辑， 代码里现在用户部分不需要密码输入用户名就能直接登录， admin和administrator为管理员用户， 下面将跳过用户部分的代码实现. 而聊天数据的传输和保存用的是redis的stream

### 代码的目录结构
![代码目录结构](/images/chatadmin-dir.png)

>目录结构
> 1. app里的api和def分别是路由函数和客户端定义的结构体
> 2. cmd目录是Gopher默认的一些命令行参数和工具， 一些websocket客户端会放里面
> 3. config用来存放配置信息
> 4. controller
> + broadcast广播器， 在用户进入离开时的操作
> + message聊天时的一些结构体定义函数
> + stream注册控制sse收听者
> + user定义和websocket发送接收的一些函数
> 5. pkg第三方包， 错误处理， eventsource功能的实现包
> 6. router注册路由函数到服务
> 7. template静态文件
> 8. web是前端vue代码目录

### sse实现
用户权限部分分为管理员和普通用户, 只有管理员才能看到所有用户信息建立sse链接, 权限这里略过
在pkg/ssevent里实现了sse广播器功能, 依赖的是go-broadcast包
```
type Manager struct {
	bcChannel broadcast.Broadcaster
	open      chan *Listener
	close     chan *Listener
	delete    chan struct{}
	messages  chan *Message
	uids      map[string]bool
	userChan  chan uidRequest
}

func NewManager() *Manager {
	manager := &Manager{
		bcChannel: broadcast.NewBroadcaster(10),
		open:      make(chan *Listener, 100),
		close:     make(chan *Listener, 100),
		delete:    make(chan struct{}, 100),
		messages:  make(chan *Message, 100),

		uids:     map[string]bool{},
		userChan: make(chan uidRequest, 10),
	}

	go manager.run()
	return manager
}
```
> Manager
> 1. bcChannel 广播器
> 2. open 是一个注册通道, 有新用户进行订阅时, 通过此通道传给广播器
> 3. close 取消订阅通道
> 4. delete 减少广播器缓存通道的长度
> 5. mesages 消息传输通道
> 6. 保存已订阅的用户ID

Listener收听者是一个结构体
```
type Listener struct {
	Channel chan interface{}
	Uid     string
}
```
里面主要是一个消息通道(Channel)和用户的id

在app/api的StreamSSEvent函数里
```
func (m *Manager) register(listener *Listener) {
	m.uids[listener.Uid] = true
	m.bcChannel.Register(listener.Channel)
}

listener := controller.StreamOpenListener(user.UID)
defer controller.StreamCloseListener(user.UID, listener)

clientGone := c.Writer.CloseNotify()
c.Stream(func(w io.Writer) bool {
    select {
    case <-clientGone:
        fmt.Println("用户离开")
        return false
    case message := <-listener:
        sseMsg, ok := message.(*ssevent.Message)
        if !ok {
            return false
        }
        c.SSEvent("message", sseMsg.Text)
        return true
    }
})
```
首先用controller.StreamOpenListener函数创建收听者并向sse广播器注册后, 返回一个消息通道, 这里服务端为每个接听者都监听一个消息通道, 当有消息提交到广播器时, 广播器会将消息发送到所有收听者的消息通道, 服务器再从消息通道接收消息并传给客户端

在controller/broadcast里
```
func (b *broadcaster) Start() {
	for {
		select {
		case user := <-b.enteringChannel:
			fmt.Println("new user: ", user)
			b.StreamUserInfos()
		case user := <-b.leavingChannel:
			user.Leave()
			b.StreamUserInfos()
		}
	}
}

func (b *broadcaster) StreamUserInfos() {
	infos := b.GetUserList()
	infoStr, _ := json.Marshal(infos)
	StreamBroadcastUserInfos(string(infoStr))
}
```
在用户进入和离开聊天室时, 都会更新当前用户列表, 并通过广播器推送到客户端


### 聊天室实现
由于聊天室里管理员和普通的用户的信息交流是通过redis的stream实现的， 所以先了解一下stream
#### Stream
Redis Stream 是 Redis 5.0 版本新增加的数据结构。
Redis Stream 主要用于消息队列（MQ，Message Queue），Redis 本身是有一个 Redis 发布订阅 (pub/sub) 来实现消息队列的功能，但它有个缺点就是消息无法持久化，如果出现网络断开、Redis 宕机等，消息就会被丢弃。
简单来说发布订阅 (pub/sub) 可以分发消息，但无法记录历史消息。而 Redis Stream 提供了消息的持久化和主备复制功能，可以让任何客户端访问任何时刻的数据，并且能记住每一个客户端的访问位置，还能保证消息不丢失

先来看一下聊天室的路由函数实现
```
func WebSocketHandle(c *gin.Context) {
	user, err := getUser(c)
	if err != nil {
		c.Error(response.WrapError(nil, "获取用户信息失败"))
		return
	}
	client := c.Query("client")
	if err := user.CanEnterRoot(client); err != nil {
		c.Error(response.WrapError(err, "加入聊天失败"))
		return
	}
	options := websocket.AcceptOptions{InsecureSkipVerify: true}
	conn, err := websocket.Accept(c.Writer, c.Request, &options)
	if err != nil {
		c.Error(err)
		return
	}
	defer conn.Close(websocket.StatusInternalError, "内部出错")

	user.Init(conn, client)

	controller.Broadcaster.UserEntering(user)

	go user.SendMessage(c.Request.Context())

	controller.Broadcaster.SendWelcomeMsg(user, c.Request.Context())

	err = user.RecieveMessage(c.Request.Context())

	controller.Broadcaster.UserLeaving(user)

	if err == nil {
		conn.Close(websocket.StatusNormalClosure, "")
	} else {
		conn.Close(websocket.StatusInternalError, "Read from client error")
	}
}
```
首先getUser从当前会话中拿到用户信息, 判断用户时候可以进入聊天室, 如果用户已经在聊天室或者管理员连接的用户已经在进行对话将被阻止, 然后websocket.Accept将http协议升级为websocket协议并且拿到连接, user.Init初始化用户, 开启一个Goroutine来向用户发送数据, 然后向用户发送欢迎数据, 接下来接收用户的数据并将数据写入到stream里面
user.Init:
```
const (
	RoleAdmin            string = "admin"            // 管理员权限
	RoleUser             string = "user"             // 普通用户权限
	userChannelFmt       string = "user:%s:channel"  // 用户发布信息的stream
	adminChannelFmt      string = "admin:%s:channel" // 用户接受信息的stream
	RChatUserHash        string = "users-map"        // 用户昵称和uid的对应map
	RChatUserSet         string = "users-set"        // 用户加入聊天系统时的集合
	RChatAdminSet        string = "admin-set"        // 初始化时加入管理员
	RChatUserAdminHash   string = "users-admin"      // 用户和管理员聊天时的绑定关系
	RChatUserEnterAtHash string = "users-enter-at"   // 用户加入聊天室的时间
	RNoSub               int64  = 0
)

type User struct {
	UID        string    `json:"uid"`
	NickName   string    `json:"nickname"`
	EnterAt    time.Time `json:"enter_at"`
	SubChannel string    `json:"-"`
	Token      string    `json:"token"`
	Role       string    `json:"role"`
	To         string    `json:"-"`
	PubChannel string    `json:"-"`
	// cache      []*Message

	conn *websocket.Conn
}

func (u *User) Init(conn *websocket.Conn, client string) {
	u.conn = conn
	u.EnterAt = time.Now()
	if u.Role == RoleAdmin {
		u.To = client
		u.SubChannel = fmt.Sprintf(userChannelFmt, client)
		u.PubChannel = fmt.Sprintf(userChannelFmt, client)
		rdb.HMSet(RChatUserAdminHash, client, u.NickName)
		newMsg := NewAdminToUserMsg(u)
		u.Publish(newMsg)
	} else {
		rdb.SAdd(RChatUserSet, u.NickName)
		u.SubChannel = fmt.Sprintf(userChannelFmt, u.NickName)
		u.PubChannel = fmt.Sprintf(userChannelFmt, u.NickName)
	}
	rdb.HMSet(RChatUserEnterAtHash, u.NickName, time.Now().Format("2006-01-02 15:04:05"))
}
```
用户的结构体主要是id，权限， websocket连接等. 主要的是SubChannel和PubChannel两个通道, 这两个通道对应的是redis的stream名称, 如果是普通用户， 服务端将为每个用户创建一个stream用于普通用户和管理员用户的数据传输。 如果是管理员用户， 将先根据用户名称找到这条stream与用户进行沟通， 同时绑定管理员与用户的关系避免其它管理员同时连接到此用户.  

先来看一下接收用户数据的函数user.RecieveMessage(c.Request.Context())
```

func (u *User) RecieveMessage(ctx context.Context) error {
	var (
		receiveMsg map[string]string
		err        error
	)
	for {
		err = wsjson.Read(ctx, u.conn, &receiveMsg)
		if err != nil {
			var closeErr websocket.CloseError
			if errors.As(err, &closeErr) {
				return nil
			} else if errors.Is(err, io.EOF) {
				return nil
			}

			return err
		}

		sendMsg := NewMessage(u, receiveMsg["content"], receiveMsg["send_time"])
		data := map[string]interface{}{"data": sendMsg.Hxe()}
		args := &redis.XAddArgs{Stream: u.PubChannel, ID: "*", Values: data}
		msgID, err := rdb.XAdd(args).Result()
		if err != nil {
			log.Println(err)
			return err
		}
		log.Println("msg id : ", msgID)
	}
}
```
这里先开启了一个死循环不断的读取用户传过来的数据, 然后写入之前定义好的stream(pubchannel), 再来看一下向用户发送数据的函数:user.SendMessage(c.Request.Context())

```
func (u *User) SendMessage(ctx context.Context) {
	args := &redis.XReadArgs{Streams: []string{u.SubChannel, "$"}, Block: time.Duration(0), Count: 1}
	for {
		stm := rdb.XRead(args).Val()
		for _, stream := range stm {
			for _, msg := range stream.Messages {
				var sendMsg Message
				data := msg.Values["data"]
				_ = json.Unmarshal([]byte(data.(string)), &sendMsg)
				if sendMsg.User.NickName != u.NickName {
					err := wsjson.Write(ctx, u.conn, &sendMsg)
					if err != nil {
						log.Println(err)
					}
				}
			}
		}
	}
}
```
从这个函数可以看到是不断的从订阅的stream(subchannel)里读取数据， 如果发送者不是自己就向用户发送通道里的数据
总结一下管理员与用户的聊天过程：
> 1. 用户登录进入聊天室, 建立发送与收听的stream
> 2. 管理员在dashboard页面上看到用户, 点击聊天
> 3. 通过用户找到相关的stream
> 4. 接收管理员和普通的数据然后通过stream进行传输
> 5. 从stream里收到对方发送的数据后再传回给浏览器
> 6. stream保留聊天数据在下次进入聊天室时进行展示

### Go1.16 embed将静态文件嵌入程序
Go在1.16版本终于发布了embed功能， Go编译的程序本来就非常部署， 但是除了编译出来的二进制文件通常还需要配置文件，静态文件等， 在实际使用中会影响部署的体验， 好在1.16中embed功能可以嵌入文件到程序里。  

> 嵌入
> 1. 对于单个的文件，支持嵌入为字符串和 byte slice
> 2. 对于多个文件和文件夹，支持嵌入为新的文件系统FS
> 3. go: embed 指令用来嵌入，必须紧跟着嵌入后的变量名

实际使用:
```
var (
	//go:embed template
	embededFiles embed.FS
	//go:embed config/chatadmin.yaml
	configData []byte
)
```
embededFiles为嵌入的静态文件, 嵌入后为文件系统 configData为嵌入的配置文件, 它是但文件, 将它解析为字节
使用文件系统:
```
templ := template.Must(template.New("").ParseFS(embededFiles, "template/*.html"))
r.SetHTMLTemplate(templ)
jsFiles, err := fs.Sub(embededFiles, "template/js")
if err != nil {
    panic(err)
}
cssFiles, err := fs.Sub(embededFiles, "template/css")
if err != nil {
    panic(err)
}
staticFiles, err := fs.Sub(embededFiles, "template/static")
if err != nil {
    panic(err)
}
r.StaticFS("/js", http.FS(jsFiles))
r.StaticFS("/css", http.FS(cssFiles))
r.StaticFS("/static", http.FS(staticFiles))
```
这样编译后只要一个单二进制程序就可以进行部署了， 而不需要连同静态文件等


__所有的代码均已上传到GitHub上__
[GitHub地址](https://github.com/chengjoey/chatadmin)