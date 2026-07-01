m = Map("apple_cdn_opt", translate("Apple CDN Optimizer"), translate("定时自动筛选和优化 Apple TV+ 及 Apple Music 优质节点并修改本地 hosts。"))

-- Dashboard Status Section
s_status = m:section(SimpleSection)
s_status.template = "apple_cdn_opt/status"

-- Global settings
s = m:section(TypedSection, "global", translate("全局设置"))
s.anonymous = true
s.addremove = false

e = s:option(Flag, "enabled", translate("启用定期自动优化"))
e.rmempty = false

c = s:option(ListValue, "cron_time", translate("运行周期"))
c:value("hour", translate("每小时"))
c:value("3hours", translate("每 3 小时"))
c:value("6hours", translate("每 6 小时"))
c:value("12hours", translate("每 12 小时"))
c:value("day", translate("每天"))
c.default = "6hours"

t = s:option(Value, "test_timeout", translate("测速超时 (秒)"), translate("Ping 和 HTTPS 握手最大等待秒数 (建议 1 - 5 秒)"))
t.datatype = "range(1, 10)"
t.default = "2"
t.rmempty = false

-- Region Selection for DoH resolution
s:option(DummyValue, "_region_title", translate("解析与测速机房设置"), translate("选择开启解析和测速的 CDN 机房区域 (基于 DoH+ECS 动态获取各地最新 IP)"))

r_hk = s:option(Flag, "region_hk", translate("中国香港 (HK)"), translate("解析子网: 203.80.96.0/24"))
r_hk.default = "1"
r_hk.rmempty = false

r_jp = s:option(Flag, "region_jp", translate("日本东京 (JP)"), translate("解析子网: 210.140.10.0/24"))
r_jp.default = "1"
r_jp.rmempty = false

r_kr = s:option(Flag, "region_kr", translate("韩国首尔 (KR)"), translate("解析子网: 168.126.63.0/24"))
r_kr.default = "1"
r_kr.rmempty = false

r_tw = s:option(Flag, "region_tw", translate("中国台湾 (TW)"), translate("解析子网: 210.200.211.0/24"))
r_tw.default = "1"
r_tw.rmempty = false

r_sg = s:option(Flag, "region_sg", translate("新加坡 (SG)"), translate("解析子网: 116.12.0.0/16"))
r_sg.default = "1"
r_sg.rmempty = false

-- Domains
s_domains = m:section(TypedSection, "domains", translate("优化业务种子域名"), translate("在这里输入 Apple TV+ 或 Apple Music 相关的核心种子域名，系统将自动基于勾选的机房衍生覆盖所有全球回切节点"))
s_domains.anonymous = true
s_domains.addremove = false

d = s_domains:option(DynamicList, "domain", translate("种子域名列表"))
d.datatype = "hostname"
d.rmempty = false

return m
