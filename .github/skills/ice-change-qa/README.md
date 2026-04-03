# ICE Change QA

这个 skill 用来在 VS Code Chat 里加载一个或多个 ICE change ID 或 change URL，并在当前会话里基于 change 信息持续回答问题。
默认只查询 change 本体。只有你明确要求“看 update / 更新历史 / 谁做了更新”时，它才会额外调用 updates 和 apiUsers。
注意：change ID 不要求是纯数字，也可以是类似 `CHG-ALPHA-7` 这样的字符串。

## 需要哪些配置

### 只做演示或离线 mock

不需要任何配置。

### 需要真实 ICE 数据

需要配置：

- `ICE_API_BASE_URL`
- `ICE_USERNAME`
- `ICE_PASSWORD`

`ICE_API_BASE_URL` 要填共享 API 根地址，例如：

```text
https://abc.com/ice/api
```

当前实现使用 Basic Auth。

## 在 VS Code Chat 里怎么用

最常用的是直接在 Chat 里提：

```text
用 $ice-change-qa 加载 change CHG-ALPHA-7，并总结当前状态
```

如果你想一次加载多个 change：

```text
用 $ice-change-qa 加载这些 change，并判断它们是否影响同一个服务：
9001, 9002, CHG-ALPHA-7
```

如果你手上是 URL：

```text
用 $ice-change-qa 把这个 change 加入当前上下文：
https://abc.com/ice/changes/CHG-ALPHA-7
```

如果你明确想看 update：

```text
用 $ice-change-qa 加载 change 9002，并说明最新 updates
```

如果你明确想看是谁更新的：

```text
用 $ice-change-qa 告诉我 change 9003 最近是谁更新的
```

如果你想在当前会话里继续追加 change：

```text
用 $ice-change-qa 再加入 CHG-ALPHA-7 和 9005，然后继续回答刚才的问题
```

如果你想基于已经加载的 change 继续追问：

```text
继续用当前加载的 ICE change 回答：哪个 change 的风险最高？
```

如果你想强制刷新当前会话缓存：

```text
用 $ice-change-qa 刷新当前 ICE change 上下文，然后重新回答刚才的问题
```

如果你想替换当前 change 集合：

```text
用 $ice-change-qa 只保留 CHG-ALPHA-7 作为当前上下文
```

如果你想清空当前上下文：

```text
用 $ice-change-qa 清空当前 ICE change 上下文
```

## 你会得到什么

通常会得到这些结果：

- 每个 change 的原始 change 信息
- 默认基于 change 构造的 QA 文本
- 只有在你明确要求时才返回 updates 原始响应
- 只有在你明确要求 updates 时才解析 `updaterApiUserID` 对应的操作者名称
- 哪些 change 查询成功、部分成功或失败的状态

## 会话行为说明

- 默认会把新 change 追加到当前会话上下文
- 如果你不再贴 ID，它会复用当前已加载的 change 集合
- 只有在你明确要求刷新时，才会重新抓取已缓存的 change
- updates 查询是按需触发的，不会因为之前查过 updates 就在普通 change 查询里自动带出来
- 如果某个 ID 的部分接口失败，它仍会返回能拿到的数据，并标记 warning 或 error
- 如果你明确说“替换”或“重置”，它会用新的 change 集合覆盖旧上下文
