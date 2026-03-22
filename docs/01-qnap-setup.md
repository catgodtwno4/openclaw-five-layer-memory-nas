# QNAP NAS 環境準備

## 前提

- QNAP NAS with Container Station 已安裝
- SSH 已啟用

## 1. SSH 帳號配置

```bash
# 從 Mac 連接
ssh openclaw@YOUR_NAS_IP
```

## 2. 配置 sudo 權限

> ⚠️ QNAP 的 sudoers 路徑是 `/usr/etc/sudoers`，**不是** `/etc/sudoers`

```bash
# 用 admin 帳號登入
ssh admin@YOUR_NAS_IP

# 加入 sudoers
echo 'openclaw ALL=(ALL) NOPASSWD: ALL' >> /usr/etc/sudoers

# 驗證
ssh openclaw@YOUR_NAS_IP "sudo -n id"
# 應返回: uid=0(admin) ...
```

### QNAP 特殊知識

| 項目 | QNAP 特性 |
|------|----------|
| uid=0 帳號名 | `admin`（不是 `root`） |
| sudoers 路徑 | `/usr/etc/sudoers` |
| Docker binary | `/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker` |
| Docker config | `/share/CACHEDEV1_DATA/.qpkg/container-station/etc/docker.json` |
| `jq` | 不可用（container-station restart 會報 jq not found，無害） |

## 3. Docker 代理配置（GFW 環境必須）

```bash
# 編輯 Docker daemon 配置
sudo tee /share/CACHEDEV1_DATA/.qpkg/container-station/etc/docker.json << 'EOF'
{
  "default-address-pools": [{"base":"172.29.0.0/16","size":22}],
  "experimental": false,
  "group": "administrators",
  "ip6tables": false,
  "log-driver": "json-file",
  "log-opts": {"max-file":"10","max-size":"10m"},
  "registry-mirrors": ["https://docker.1ms.run","https://dockerpull.org"],
  "proxies": {
    "http-proxy": "http://YOUR_PROXY:7890",
    "https-proxy": "http://YOUR_PROXY:7890",
    "no-proxy": "localhost,127.0.0.1,10.10.10.*"
  }
}
EOF

# 重啟 Docker
sudo /share/CACHEDEV1_DATA/.qpkg/container-station/container-station.sh restart
```

> ⚠️ **必須同時配 registry-mirrors + proxies**。只配鏡像源會很慢（50KB/s），只配代理可能 DNS 污染。

## 4. 建立部署目錄

```bash
DEPLOY=/share/CACHEDEV1_DATA/Container/openclaw-memory
mkdir -p $DEPLOY/{memos-data,neo4j-data,qdrant-data,cognee-data,cognee-patches}
cd $DEPLOY
```

## 5. SSH 注意事項

- 長操作會超時（exit code 255），用 `nohup` 或 `&` 背景執行
- `ServerAliveInterval=15` 可以減少斷線
- 大型 Docker build 建議用 `sudo sh -c '... > /tmp/build.log 2>&1; echo $? > /tmp/build-rc' &`
