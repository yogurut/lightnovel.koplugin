# lightnovel.koplugin

> ✅ **当前为 `dev` 开发分支**（仓库默认分支）。
>
> - 日常开发与**正式发版（打 tag）**都在本分支进行
> - 稳定版请到 [Releases](https://github.com/yogurut/lightnovel.koplugin/releases) 下载
> - [`master`](https://github.com/yogurut/lightnovel.koplugin/tree/master) 仅作镜像/备份，标注为开发中

在 [KOReader](https://github.com/koreader/koreader) 中阅读[轻书架](https://www.lightnovel.life)（lightnovel.app / lightnovel.life）的小说。

![状态](https://img.shields.io/badge/status-开发中-orange)
![分支](https://img.shields.io/badge/branch-dev-blue)

## 特性

- 邮箱 + 密码登录（密码 SHA-256 后传输）
- 通过 SignalR（MessagePack 协议）调用站点 Hub 接口
- **章节正文字体解密还原**（见下文，这是本插件最核心的部分）
- 纯 Lua 实现，无额外二进制依赖（自带 WebSocket / MessagePack / SHA-256）
- 适配墨水屏：无动画、无网络图片可关闭

## 字体加密是怎么回事

轻书架对章节正文做了**字体映射混淆**，机制如下：

1. 服务端按书生成一个字体文件（如 `/font/cb29a534….woff2`），
   把这个字体的 **cmap 打乱** —— 让码位 `U+6C9B`（`沛`）上挂的其实是 **`魔`** 的字形。
2. 正文 `Content` 字段里用**被打乱后的码位**书写，
   于是「魔女茶会」在接口里返回的是「沛际茶姜」。
3. 前端用 `@font-face{font-family:read; src:url(/font/xxx.woff2)}` 加载这个字体渲染，
   取 `沛` 的码位 → 拿到 `魔` 的字形 → **读者看到的是正确文字**。

所以**不需要做任何字符识别或映射表**，只要让 KOReader 用同一个字体渲染正文即可。

关键实现点：

- 服务端**同时提供 `.ttf`**（`/font/{hash}.ttf`），与 `.woff2` 的 cmap 完全一致。
  这绕开了「KOReader 无 brotli、解不了 woff2」的问题。
- 字体**必须动态下载**。hash 会随服务端轮换（实测同一本书不同时间拿到不同 hash），
  因此**不能预置静态映射表**。
- 字体 `name` 表被服务端清空（0 条目），本插件依赖**文件名**作为 family 名。

## 安装

1. 下载本仓库，放到 KOReader 的插件目录：

   ```
   koreader/plugins/lightnovel.koplugin/
   ```

   目录结构应为：

   ```
   lightnovel.koplugin/
   ├── _meta.lua
   ├── main.lua
   └── lightnovel/
       ├── api.lua
       ├── auth.lua
       ├── content.lua
       ├── font.lua
       ├── info.lua
       ├── logger.lua
       ├── msgpack.lua
       ├── sha256.lua
       ├── signalr.lua
       ├── state.lua
       └── websocket.lua
   ```

2. 重启 KOReader。
3. 菜单 → **工具** → **轻书架**。

## 使用

| 菜单项 | 说明 |
| --- | --- |
| 登录 | 输入邮箱和密码，登录成功后 Token 保存在 `settings/lightnovel/auth.json` |
| 打开书籍（输入 ID） | 网页版链接 `/book/12345` 里的数字 |
| 测试字体解密 | **重要**：拉取第 1 章并检查字体是否下载/注册成功 |
| 默认测试书籍 ID | 记住一本书 ID，方便反复测试 |
| 设置 | 切换服务器线路、清理缓存、查看日志路径 |
| 关于 | 版本信息 |

## 测试指南

### 第 0 步：确认能装能跑

1. 把 `lightnovel.koplugin` 放进 `koreader/plugins/`，重启 KOReader。
2. 打开菜单 → **工具** → 应该能看到 **轻书架**。
3. 打开 `koreader/crash.log`，不应有 `lightnovel` 相关报错。

#### 排查：菜单里找不到「轻书架」

按下面顺序检查，每一步都能缩小范围。

**第一步：确认插件目录结构对不对**

```
koreader/plugins/lightnovel.koplugin/     ← 必须是这个目录名（含 .koplugin）
├── _meta.lua                             ← 必须在这一层
├── main.lua                              ← 必须在这一层
└── lightnovel/                           ← 子模块目录
    ├── api.lua
    └── ...
```

常见错误：解压后变成双层目录
`plugins/lightnovel.koplugin/lightnovel.koplugin/main.lua` ❌
把里面那层的内容移到外层即可。

**第二步：看自检标记**

插件加载后会写一个标记文件：

```
koreader/settings/lightnovel/loaded.txt
```

| 文件内容 | 含义 |
|---|---|
| 文件不存在 | `main.lua` 没被加载：目录名/结构不对，或加载时崩溃 |
| `stage=module` | 模块加载了，但 `init()` 没跑 |
| `stage=menu_ok` | ✅ 菜单已注册，应该能看到 |
| `stage=menu_failed: ...` | 注册报错，后面跟着原因 |
| `stage=no_ui_menu` | 当时没有 `ui.menu`（正常会自动注册） |

**第三步：看 crash.log**

```bash
# 设备上或电脑上
cat koreader/crash.log | grep -i lightnovel
```

**第四步：确认在哪找菜单**

入口在 **工具** 菜单（`sorting_hint = "tools"`），不是在「搜索」或「设置」里。

- 文件管理器：菜单 → **工具**
- 打开任意一本书后：菜单 → **工具**

**第五步：需要重启，不是刷新**

KOReader 只在启动时扫描 `plugins/`。拷贝插件后必须**完全退出再打开**，
不能只返回书架。

#### 代码层面的原因（给自己改代码时看）

1. **插件必须是 `WidgetContainer` 的子类**。
   如果 `main.lua` 里写的是 `local P = {}` 而不是
   `local P = WidgetContainer:extend{...}`，KOReader 不会接管它的菜单，
   但插件管理页仍会读出 `_meta.lua` 里的名字——于是出现「列表里有、菜单里没有」。

2. **所有 `require` 都要容错**。
   `main.lua` 顶层只要有一个 `require` 抛错，整个插件就被跳过，
   而 `_meta.lua` 是单独读的，于是名字还在列表里。用 `pcall` / `safe_require` 包裹。

3. **`init()` 里要手动注册菜单**。
   KOReader 只会为文件管理器自动注册；在阅读器界面里需要：

   ```lua
   function P:init()
       WidgetContainer.init(self)
       if self.ui and self.ui.menu then
           self.ui.menu:registerToMainMenu(self)
       end
   end
   ```

4. **`is_doc_only` 要为 `false`**，否则只在打开书籍后才出现。

5. **`_meta.lua` 的 `name` 要和主类的 `name` 一致**。

6. **`sorting_hint` 决定菜单位置**：`"tools"` → 工具菜单，
   `"search"` → 搜索菜单，`"setting"` → 设置菜单。

不用上设备也能测这段逻辑：

```bash
lua5.1 test/test_menu.lua
```

它会用 `test/menu-stubs/` 里的 KOReader 模块桩，完整模拟
「加载 → 实例化 → init → 注册菜单 → 展开子菜单」的链路。

### 第 1 步：登录

1. 轻书架 → **登录**，输入邮箱密码。
2. 成功会弹「登录成功」。
3. 失败时看日志，或用「关于」里的路径找到日志文件：
   `koreader/settings/lightnovel/lightnovel.log`

### 第 2 步：验证字体解密（最关键）

1. 轻书架 → **默认测试书籍 ID** → 填 `20287`（一本公开测试书）。
2. 轻书架 → **测试字体解密**。
3. 弹出的信息里应该看到：

   ```
   书籍 ID: 20287
   章节标题: 『…』
   正文字符数: 12345
   字体路径: /font/xxxxxxxx….woff2
   字体 hash: xxxxxxxx…
   ✅ 字体已下载: /…/lightnovel-fonts/xxxxxxxx….ttf
   ✅ 已注册到: /…/fonts/lightnovel/ln_xxxxxxxx….ttf
   ```

4. 如果有 ❌，把日志贴出来：

   ```
   koreader/settings/lightnovel/lightnovel.log
   ```

### 第 3 步：验证正文渲染正确

这是**判断字体方案是否成功的唯一标准**：

1. 轻书架 → **打开书籍（输入 ID）** → `20287`。
2. 观察正文显示的是**正常汉字**，还是**乱码/方块**。

   - ✅ **正常汉字** → 字体方案生效，破解完成
   - ❌ **乱码或方块** → 字体没被 crengine 应用，见下方排查

### 排查：正文乱码/方块

按可能性排序：

1. **字体没注册成功**
   检查 `koreader/fonts/lightnovel/` 下有没有 `ln_xxxx.ttf`。
   没有说明 `Font.register()` 失败，看日志。

2. **crengine 需要重启才认新字体**
   crengine 的字体列表在启动时构建。运行时新增字体后，
   部分固件不会自动重扫。**退出 KOReader 再进一次**再试。

3. **name 表为空导致字体加载失败**
   服务端清空了 name 表。若 crengine 不认文件名作为 family，
   需要在插件里给 ttf 补一个 name 表（当前版本尚未实现，属已知限制）。

4. **CSS 优先级不够**
   如果阅读器设置了「强制用户字体」，会覆盖插件注入的 CSS。
   设置 → 字体 → 关闭「使用自定义字体」。

### 开发者：命令行验证字体（无需 KOReader）

已经确认过的事实，可用下面命令复现：

```bash
# 1. 拉一章，拿到 Font 路径（需要 Node.js + 登录）
node test/getboth.js        # 见 test/ 目录

# 2. 下载 ttf
curl -o /tmp/ln.ttf "https://api.lightnovel.life/font/<hash>.ttf"

# 3. 用 Python 看字形
python3 -c "
from fontTools.ttLib import TTFont
f = TTFont('/tmp/ln.ttf')
print('字形数:', f['maxp'].numGlyphs)
print('CJK 码位:', sum(1 for c in f.getBestCmap() if 0x4E00<=c<=0x9FFF))
"
```

## 已知限制

- **信号连接**：部分网络环境下 SignalR 的 WebSocket 握手会返回 `HTTP 404`。
  Node.js 客户端在同一网络下可正常连接，原因待查。
- **字体 name 表为空**：依赖 crengine 用文件名作为 family 名的 fallback 行为。
- **书架 / 搜索 UI** 尚未实现，当前仅支持按 ID 打开书籍。
- 字体 hash 轮换后，旧缓存会失效并重新下载（`设置 → 清理字体缓存` 可手动清理）。

## 目录结构

```
lightnovel.koplugin/
├── _meta.lua              插件元信息
├── main.lua               入口、菜单、UI
└── lightnovel/
    ├── info.lua           常量与版本
    ├── logger.lua         日志
    ├── state.lua          状态与配置持久化
    ├── api.lua            网络适配层（自动注入鉴权头）
    ├── auth.lua           登录 / Token 刷新 / HTTP 底层
    ├── signalr.lua        SignalR 客户端（握手 / invoke / 帧解析）
    ├── websocket.lua      纯 Lua WebSocket（RFC 6455）
    ├── msgpack.lua        纯 Lua MessagePack 编解码
    ├── sha256.lua         纯 Lua SHA-256
    ├── font.lua           字体下载 / 缓存 / 注册 / CSS 注入
    └── content.lua        章节拉取与 HTML 组装
```

## 协议要点（供参考）

- API 基址：`https://api.lightnovel.life`（备用 `https://cf-api.lightnovel.life`）
- 登录：`POST /api/user/login`，body `{email, password: sha256(password)}`，需 `x-id` 指纹头
- 通信：SignalR Hub `/hub/api` + MessagePack
- **所有 invoke 必须带 `{UseGzip: false}` 作为最后一个参数**，否则服务端报
  `Failed to invoke due to an error on the server`
- negotiate：`POST /hub/api/negotiate?negotiateVersion=1`，WebSocket 用 **`connectionToken`** 而非 `connectionId`
- 常用方法：`GetBookShelf`、`GetBookInfo`、`GetNovelContent`、`GetBookListByTitle`、`SaveReadPosition` …

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 致谢

- 交互协议参考 [hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin) 的插件结构
- 本项目与轻书架官方无关联
