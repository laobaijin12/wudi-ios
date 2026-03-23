# WebSocket 事件文档

## 1. 连接信息

- WS URL: `/ws_sync_api/ws`
- 传输格式: 文本 JSON

客户端请求统一结构:

```json
{
  "event_type": "事件名",
  "params": {}
}
```

服务端推送统一结构:

```json
{
  "type": "事件名",
  "data": {}
}
```

错误响应统一结构:

```json
{
  "type": "事件名",
  "data": {
    "error": "错误信息"
  }
}
```

## 2. 事件: `get_unread_count`

### 2.1 功能

按实例批量获取当前用户未读数（与 HTTP `GetAllUnreadCount` 逻辑一致）。

### 2.2 请求参数

请求:

```json
{
  "event_type": "get_unread_count",
  "params": {
    "instance_ids": ["1", "2_business"]
  }
}
```

参数说明:

- `instance_ids` 必填，实例 ID 列表。
- 支持 `string[]`（推荐）; 兼容单个 `string`。
- 不从 session 推断实例，必须显式传入。

### 2.3 成功响应

```json
{
  "type": "get_unread_count",
  "data": {
    "message": "success",
    "data": {
      "1": {
        "jid_a@xxx": "3",
        "jid_b@xxx": "1"
      },
      "2_business": {}
    }
  }
}
```

字段说明:

- `data.data` 为 map，key 是 `instance_id`。
- 每个实例下的 value 是 `jid -> unread_count` 的 map（字符串值）。

### 2.4 失败响应示例

```json
{
  "type": "get_unread_count",
  "data": {
    "error": "instance_ids不能为空"
  }
}
```

## 3. 事件: `clear_unread`

### 3.1 功能

清除指定实例、指定会话 `jid` 的未读数（与 HTTP `ClearUnread` 逻辑一致）。

### 3.2 请求参数

请求:

```json
{
  "event_type": "clear_unread",
  "params": {
    "instance_id": "1",
    "jid": "8613812345678@s.whatsapp.net"
  }
}
```

参数说明:

- `instance_id` 必填，实例 ID。
- `jid` 必填，会话 JID。
- 不从 session 推断实例，必须显式传入。

### 3.3 成功响应

```json
{
  "type": "clear_unread",
  "data": {
    "message": "success"
  }
}
```

### 3.4 失败响应示例

```json
{
  "type": "clear_unread",
  "data": {
    "error": "jid不能为空"
  }
}
```

## 4. 事件: `fetch_messages_status`

### 4.1 功能

开启消息状态同步监控（与 HTTP `GetMessageByKeyIDV2` 查询逻辑一致，并增加持续监控能力）:

- 每 5 秒查询一次消息状态。
- 单个 `msg_id` 同一时间最多一个监控线程（重复请求同一个 `msg_id` 会返回已存在监控提示）。
- 单个线程最多存活 3 分钟。（不能一直存活，否则会占用资源，考虑每三分钟重新调用fetch_messages_status一次）
- 查询到的消息 `status` 与数据库当前值对比，若不同则推送该消息对象。
- 当 `status = 13`（已读）时，立即停止该监控线程。

### 4.2 请求参数

请求:

```json
{
  "event_type": "fetch_messages_status",
  "params": {
    "instance_id": "1",
    "msg_id": "123456789",
    "chat_row_id": "9527",
    "box_ip": "10.10.10.20",
    "index": "1",
    "ws_type": "xxx",
    "uuid": "optional-uuid"
  }
}
```

参数说明:

- `instance_id` 必填，实例 ID。
- `msg_id` 必填，消息 ID（支持字符串或数字输入，内部按字符串处理）。
- `chat_row_id` 必填。
- `box_ip` 必填。
- `index` 必填。
- `ws_type` 选填，透传到内部查询。
- `uuid` 选填，透传到内部查询。

注意:

- `chat_row_id`、`box_ip`、`index` 均为强制参数，必须在 `params` 中传入。
- 不会从 session 或其他上下文自动补全这些字段。

### 4.3 启动成功响应

首次启动监控:

```json
{
  "type": "fetch_messages_status",
  "data": {
    "message": "success",
    "msg_id": "123456789",
    "instance_id": "1"
  }
}
```

若同一 `msg_id` 已有监控在运行:

```json
{
  "type": "fetch_messages_status",
  "data": {
    "message": "monitor already running",
    "msg_id": "123456789"
  }
}
```

### 4.4 监控过程推送

当检测到 `status` 变化时，推送消息对象（`data` 为消息详情对象，结构与 `GetMessageByKeyIDV2` 返回一致）:

```json
{
  "type": "fetch_messages_status",
  "data": {
    "id": 10001,
    "instance_id": "1",
    "jid": "123456789@xxx",
    "status": 8
  }
}
```

当轮询过程中发生错误时:

```json
{
  "type": "fetch_messages_status",
  "data": {
    "msg_id": "123456789",
    "error": "错误信息"
  }
}
```

### 4.5 停止条件

监控线程在以下任一条件满足时停止:

- 客户端断开连接。
- 监控运行达到 3 分钟超时。
- 查询结果 `status = 13`。

## 5. 其他说明

- `event_type` 不支持时会返回:

```json
{
  "type": "原event_type",
  "data": {
    "error": "unsupported event_type"
  }
}
```
