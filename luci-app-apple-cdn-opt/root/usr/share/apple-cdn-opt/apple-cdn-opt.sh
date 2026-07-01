#!/bin/sh

LOCK_FILE="/var/run/apple-cdn-opt.lock"
RESULT_JSON="/var/run/apple_cdn_opt.json"
HOSTS_FILE="/etc/apple_cdn_opt.hosts"

# Lock file logic to prevent concurrent runs
if [ -f "$LOCK_FILE" ]; then
	old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
	if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
		echo "Apple CDN Optimizer is already running (PID: $old_pid)."
		exit 1
	fi
fi
echo "$$" > "$LOCK_FILE"

# Clean up lock file on exit
trap 'rm -f "$LOCK_FILE"; exit' INT TERM EXIT

# Set status to running
if [ -f "$RESULT_JSON" ]; then
	sed -i 's/"status":"[^"]*"/"status":"running"/g' "$RESULT_JSON"
else
	echo '{"status":"running","domains":{}}' > "$RESULT_JSON"
fi

# Load configuration values from UCI using anonymous section index notation
DOMAINS=$(uci -q get apple_cdn_opt.@domains[0].domain | tr '\n' ' ')
TIMEOUT=$(uci -q get apple_cdn_opt.@global[0].test_timeout)
[ -z "$TIMEOUT" ] && TIMEOUT=2

# Read enabled subnets dynamically from UCI region checkboxes
ACTIVE_SUBNETS=""
[ "$(uci -q get apple_cdn_opt.@global[0].region_hk)" = "1" ] && ACTIVE_SUBNETS="$ACTIVE_SUBNETS 203.80.96.0/24"
[ "$(uci -q get apple_cdn_opt.@global[0].region_jp)" = "1" ] && ACTIVE_SUBNETS="$ACTIVE_SUBNETS 210.140.10.0/24"
[ "$(uci -q get apple_cdn_opt.@global[0].region_kr)" = "1" ] && ACTIVE_SUBNETS="$ACTIVE_SUBNETS 168.126.63.0/24"
[ "$(uci -q get apple_cdn_opt.@global[0].region_tw)" = "1" ] && ACTIVE_SUBNETS="$ACTIVE_SUBNETS 210.200.211.0/24"
[ "$(uci -q get apple_cdn_opt.@global[0].region_sg)" = "1" ] && ACTIVE_SUBNETS="$ACTIVE_SUBNETS 116.12.0.0/16"
# Fallback if no regions are selected (enable all)
[ -z "$ACTIVE_SUBNETS" ] && ACTIVE_SUBNETS="203.80.96.0/24 210.140.10.0/24 168.126.63.0/24 210.200.211.0/24 116.12.0.0/16"

# Check if domains are configured
if [ -z "$DOMAINS" ]; then
	echo "Error: No domains configured."
	echo "{\"status\":\"error\",\"error\":\"配置为空\",\"domains\":{}}" > "$RESULT_JSON"
	exit 1
fi

# Prepare tmp folder for parallel test tasks
TMP_DIR="/tmp/apple-cdn-opt"
mkdir -p "$TMP_DIR"
rm -f "$TMP_DIR"/*

# Helper to identify domain types
is_tv_domain() {
	case "$1" in
		*tv.apple.com*) return 0 ;;
		*) return 1 ;;
	esac
}

is_music_domain() {
	case "$1" in
		*itunes.apple.com*|*aaplimg.com*|*music.apple.com*) return 0 ;;
		*) return 1 ;;
	esac
}

# Auto-expand TV+ Fallback domains (about 104 domains)
expand_tv_domains() {
	local prefix suffix region
	for prefix in vod download; do
		for suffix in aoc amt im svod; do
			echo "${prefix}-${suffix}.tv.apple.com"
			for region in ap ap1 ap2 ap3 ap4 ap5 ap6 ap7 ap8 fa us eu; do
				echo "${prefix}-${region}-${suffix}.tv.apple.com"
			done
		done
	done
}

# Auto-expand Apple Music / iTunes Fallback domains (about 134 domains)
expand_music_domains() {
	local prefix domain region
	for prefix in aod mvod vod hls-svod; do
		for domain in itunes.apple.com itunes.g.aaplimg.com; do
			echo "${prefix}.${domain}"
			for region in ap ap1 ap2 ap3 ap4 ap5 ap6 ap7 ap8 fa us eu; do
				echo "${prefix}-${region}.${domain}"
			done
		done
	done

	# HLS SVOD -ve fallbacks (e.g. hls-svod-aoc-ve.itunes.g.aaplimg.com / .itunes.apple.com)
	for region in aoc amt im ap ap1 ap2 ap3 ap4 ap5 ap6 ap7 ap8 fa us eu; do
		echo "hls-svod-${region}-ve.itunes.g.aaplimg.com"
		echo "hls-svod-${region}-ve.itunes.apple.com"
	done
}

# Resolve domain using DNS over HTTPS (DoH) with EDNS Client Subnet (ECS) to query regional DNS dynamically
resolve_doh_ecs() {
	local domain="$1"
	local subnet="$2"
	local api_url response
	
	# Try AliDNS first
	api_url="https://dns.alidns.com/resolve"
	response=$(curl -k -s --connect-timeout 2 --max-time 4 "${api_url}?name=${domain}&type=1&edns_client_subnet=${subnet}")
	
	# Fallback to Google DNS if AliDNS fails
	if [ -z "$response" ] || ! echo "$response" | grep -q '"Answer"'; then
		api_url="https://dns.google/resolve"
		response=$(curl -k -s --connect-timeout 2 --max-time 4 "${api_url}?name=${domain}&type=1&edns_client_subnet=${subnet}")
	fi
	
	if [ -n "$response" ]; then
		echo "$response" | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | cut -d'"' -f4 | grep '^17\.'
	fi
}

# Helper to append unique IPs to a list
append_ips() {
	local current="$1"
	local new="$2"
	local ip
	for ip in $new; do
		if ! echo "$current" | grep -q "$ip"; then
			current="$current $ip"
		fi
	done
	echo "$current"
}

# Core test function for a single IP address
test_ip() {
	local ip="$1"
	local domain="$2"
	local outfile="$3"

	echo "[测试] 正在测速 IP: $ip ($domain)..."

	# 1. Ping Test (4 packets, timeout per packet is $TIMEOUT seconds)
	local ping_out loss avg_rtt jitter rtt_line rtt_vals min_rtt max_rtt
	ping_out=$(ping -c 4 -W "$TIMEOUT" "$ip" 2>/dev/null)
	loss=$(echo "$ping_out" | grep -oE '[0-9]+% packet loss' | cut -d% -f1)
	[ -z "$loss" ] && loss=100

	avg_rtt="9999"
	jitter="9999"
	if [ "$loss" -ne 100 ]; then
		rtt_line=$(echo "$ping_out" | grep -E 'round-trip|rtt')
		if [ -n "$rtt_line" ]; then
			rtt_vals=$(echo "$rtt_line" | cut -d'=' -f2 | tr -d 'ms ')
			min_rtt=$(echo "$rtt_vals" | cut -d'/' -f1)
			avg_rtt=$(echo "$rtt_vals" | cut -d'/' -f2)
			max_rtt=$(echo "$rtt_vals" | cut -d'/' -f3)
			jitter=$(echo "$rtt_vals" | cut -d'/' -f4)

			# Fallback if jitter (mdev/stddev) is not returned
			if [ -z "$jitter" ] || [ "$jitter" = "$avg_rtt" ]; then
				# Jitter = (max - min) / 2
				jitter=$(awk "BEGIN {print ($max_rtt - $min_rtt) / 2}")
			fi
		fi
	fi

	# 2. HTTPS Connection Test (curl to verify TLS handshake and latency)
	local https_ok http_code curl_exit curl_out raw_ssl ssl_time
	https_ok=0
	http_code=0
	ssl_time="9999"
	if [ "$loss" -ne 100 ]; then
		curl_out=$(curl -k -s -o /dev/null -w "%{http_code}|%{time_appconnect}" --connect-timeout "$TIMEOUT" --max-time 5 --resolve "$domain:443:$ip" "https://$domain/")
		curl_exit=$?
		if [ $curl_exit -eq 0 ]; then
			https_ok=1
			http_code=$(echo "$curl_out" | cut -d'|' -f1)
			raw_ssl=$(echo "$curl_out" | cut -d'|' -f2)
			# Convert to milliseconds (e.g. 0.261420 -> 261.4)
			ssl_time=$(awk "BEGIN {printf \"%.1f\", $raw_ssl * 1000}")
		fi
	fi

	# Print diagnosis log
	if [ "$loss" -eq 100 ]; then
		echo "[测试] IP: $ip 测速失败: Ping 丢包率 100% (网络不通)"
	elif [ "$https_ok" -ne 1 ]; then
		echo "[测试] IP: $ip 测速警告: Ping = ${avg_rtt}ms, 但 HTTPS 握手失败 (curl 退出码: $curl_exit)"
	else
		echo "[测试] IP: $ip 测速成功: Ping = ${avg_rtt}ms, HTTPS 握手 = ${ssl_time}ms"
	fi

	# Write results to output file
	echo "$ip|$loss|$avg_rtt|$jitter|$https_ok|$http_code|$ssl_time" > "$outfile"
}

# Determine representative domains for testing pools
REP_TV_DOMAIN=""
REP_MUSIC_DOMAIN=""
for domain in $DOMAINS; do
	if [ -z "$REP_TV_DOMAIN" ] && is_tv_domain "$domain"; then
		REP_TV_DOMAIN="$domain"
	fi
	if [ -z "$REP_MUSIC_DOMAIN" ] && is_music_domain "$domain"; then
		REP_MUSIC_DOMAIN="$domain"
	fi
done
[ -z "$REP_TV_DOMAIN" ] && REP_TV_DOMAIN="vod-ap-aoc.tv.apple.com"
[ -z "$REP_MUSIC_DOMAIN" ] && REP_MUSIC_DOMAIN="mvod.itunes.apple.com"

# Classify and collect IP addresses from DNS queries
TV_IPS=""
MUSIC_IPS=""
OTHER_DOMAINS=""

for domain in $DOMAINS; do
	echo "Resolving candidate IPs for: $domain"
	candidate_ips=""
	
	# Dynamically resolve live IPs from the enabled regional DNS authorities
	# using DNS over HTTPS (DoH) with EDNS Client Subnet (ECS) to prevent any local DNS hijacking.
	for subnet in $ACTIVE_SUBNETS; do
		ips=$(resolve_doh_ecs "$domain" "$subnet")
		for ip in $ips; do
			if ! echo "$candidate_ips" | grep -q "$ip"; then
				candidate_ips="$candidate_ips $ip"
			fi
		done
	done

	if is_tv_domain "$domain"; then
		TV_IPS=$(append_ips "$TV_IPS" "$candidate_ips")
	elif is_music_domain "$domain"; then
		MUSIC_IPS=$(append_ips "$MUSIC_IPS" "$candidate_ips")
	else
		OTHER_DOMAINS="$OTHER_DOMAINS $domain"
		# Save IP pool for this specific domain
		echo "$candidate_ips" > "$TMP_DIR/ips_$(echo "$domain" | tr '.' '_')"
	fi
done

# Launch parallel tests for all collected IPs
echo "Testing IP pools..."

# 1. TV Pool
if [ -n "$TV_IPS" ]; then
	count=0
	for ip in $TV_IPS; do
		test_ip "$ip" "$REP_TV_DOMAIN" "$TMP_DIR/tv_${ip}" &
		count=$((count + 1))
		if [ $((count % 8)) -eq 0 ]; then
			wait
		fi
	done
	wait
fi

# 2. Music Pool
if [ -n "$MUSIC_IPS" ]; then
	count=0
	for ip in $MUSIC_IPS; do
		test_ip "$ip" "$REP_MUSIC_DOMAIN" "$TMP_DIR/music_${ip}" &
		count=$((count + 1))
		if [ $((count % 8)) -eq 0 ]; then
			wait
		fi
	done
	wait
fi

# 3. Other Pool
count=0
for domain in $OTHER_DOMAINS; do
	ips_file="$TMP_DIR/ips_$(echo "$domain" | tr '.' '_')"
	if [ -f "$ips_file" ]; then
		ips=$(cat "$ips_file")
		for ip in $ips; do
			test_ip "$ip" "$domain" "$TMP_DIR/other_${domain}_${ip}" &
			count=$((count + 1))
			if [ $((count % 8)) -eq 0 ]; then
				wait
			fi
		done
	fi
done
wait

# Query geolocations in parallel for all unique tested IPs
echo "正在查询节点真实地理位置..."
ALL_UNIQUE_IPS=""
for ip in $TV_IPS $MUSIC_IPS; do
	if ! echo "$ALL_UNIQUE_IPS" | grep -q "$ip"; then
		ALL_UNIQUE_IPS="$ALL_UNIQUE_IPS $ip"
	fi
done
for domain in $OTHER_DOMAINS; do
	ips_file="$TMP_DIR/ips_$(echo "$domain" | tr '.' '_')"
	if [ -f "$ips_file" ]; then
		for ip in $(cat "$ips_file"); do
			if ! echo "$ALL_UNIQUE_IPS" | grep -q "$ip"; then
				ALL_UNIQUE_IPS="$ALL_UNIQUE_IPS $ip"
			fi
		done
	fi
done

mkdir -p "$TMP_DIR/geo"
geo_count=0
for ip in $ALL_UNIQUE_IPS; do
	(
		country_code=""
		# 1. Try to query IP.SB first (Live API priority)
		geo_out=$(curl -s -A "Mozilla/5.0" --connect-timeout 2 --max-time 3 "https://api.ip.sb/geoip/$ip")
		country_code=$(echo "$geo_out" | grep -oE '"country_code":"[^"]+"' | cut -d'"' -f4)
		
		# 2. If failed, try ip-api.com
		if [ -z "$country_code" ]; then
			geo_out=$(curl -s --connect-timeout 2 --max-time 3 "http://ip-api.com/json/$ip")
			country_code=$(echo "$geo_out" | grep -oE '"countryCode":"[^"]+"' | cut -d'"' -f4)
		fi
		
		# 3. Fallback to the 100% verified local dictionary if API failed
		if [ -z "$country_code" ]; then
			if echo "$ip" | grep -qE '^17\.253\.(84\.|85\.|86\.|87\.)'; then
				country_code="HK"
			elif echo "$ip" | grep -qE '^17\.253\.(69\.|71\.|75\.)'; then
				country_code="JP"
			elif echo "$ip" | grep -qE '^17\.253\.(114\.|115\.)'; then
				country_code="KR"
			elif echo "$ip" | grep -qE '^17\.253\.(112\.|113\.)'; then
				country_code="FR"
			fi
		fi
		
		# 4. Set default to Unknown if all failed
		if [ -z "$country_code" ]; then
			country_code="Unknown"
		fi
		
		echo "$country_code" > "$TMP_DIR/geo/$ip"
	) &
	geo_count=$((geo_count + 1))
	if [ $((geo_count % 8)) -eq 0 ]; then
		wait
	fi
done
wait

# Compile and sort TV results
if [ -n "$TV_IPS" ]; then
	for ip in $TV_IPS; do
		outfile="$TMP_DIR/tv_${ip}"
		if [ -f "$outfile" ]; then
			data=$(cat "$outfile")
			c_ip=$(echo "$data" | cut -d'|' -f1)
			c_loss=$(echo "$data" | cut -d'|' -f2)
			c_avg=$(echo "$data" | cut -d'|' -f3)
			c_jit=$(echo "$data" | cut -d'|' -f4)
			c_https=$(echo "$data" | cut -d'|' -f5)
			c_code=$(echo "$data" | cut -d'|' -f6)
			c_ssl=$(echo "$data" | cut -d'|' -f7)
			
			# Zero-pad values to bypass BusyBox sort multicomponent floats sorting bugs
			fmt_loss=$(printf "%03d" "$c_loss" 2>/dev/null || echo "100")
			fmt_avg=$(printf "%08.2f" "$c_avg" 2>/dev/null || echo "9999.00")
			fmt_jit=$(printf "%08.2f" "$c_jit" 2>/dev/null || echo "9999.00")
			
			# Calculate sort score: (1 - c_https) * 1000000 + c_loss * 10000 + c_avg
			score_latency="$c_avg"
			[ "$score_latency" = "9999" ] && score_latency="9999.00"
			sort_score=$(awk "BEGIN {print (1 - $c_https) * 1000000 + $c_loss * 10000 + $score_latency}")
			fmt_score=$(printf "%015.2f" "$sort_score" 2>/dev/null || echo "9999999.00")
			
			c_geo=$(cat "$TMP_DIR/geo/$c_ip" 2>/dev/null || echo "Other")
			echo "$fmt_score $c_https $fmt_loss $fmt_avg $fmt_jit $c_ip $c_code $c_ssl $c_geo" >> "$TMP_DIR/raw_tv"
		fi
	done
	if [ -f "$TMP_DIR/raw_tv" ]; then
		# Standard single column numeric ascending sort (lowest score is best)
		sort -n "$TMP_DIR/raw_tv" > "$TMP_DIR/sorted_tv"
	fi
fi

# Compile and sort Music results
if [ -n "$MUSIC_IPS" ]; then
	for ip in $MUSIC_IPS; do
		outfile="$TMP_DIR/music_${ip}"
		if [ -f "$outfile" ]; then
			data=$(cat "$outfile")
			c_ip=$(echo "$data" | cut -d'|' -f1)
			c_loss=$(echo "$data" | cut -d'|' -f2)
			c_avg=$(echo "$data" | cut -d'|' -f3)
			c_jit=$(echo "$data" | cut -d'|' -f4)
			c_https=$(echo "$data" | cut -d'|' -f5)
			c_code=$(echo "$data" | cut -d'|' -f6)
			c_ssl=$(echo "$data" | cut -d'|' -f7)
			
			# Zero-pad values to bypass BusyBox sort multicomponent floats sorting bugs
			fmt_loss=$(printf "%03d" "$c_loss" 2>/dev/null || echo "100")
			fmt_avg=$(printf "%08.2f" "$c_avg" 2>/dev/null || echo "9999.00")
			fmt_jit=$(printf "%08.2f" "$c_jit" 2>/dev/null || echo "9999.00")
			
			# Calculate sort score: (1 - c_https) * 1000000 + c_loss * 10000 + c_avg
			score_latency="$c_avg"
			[ "$score_latency" = "9999" ] && score_latency="9999.00"
			sort_score=$(awk "BEGIN {print (1 - $c_https) * 1000000 + $c_loss * 10000 + $score_latency}")
			fmt_score=$(printf "%015.2f" "$sort_score" 2>/dev/null || echo "9999999.00")
			
			c_geo=$(cat "$TMP_DIR/geo/$c_ip" 2>/dev/null || echo "Other")
			echo "$fmt_score $c_https $fmt_loss $fmt_avg $fmt_jit $c_ip $c_code $c_ssl $c_geo" >> "$TMP_DIR/raw_music"
		fi
	done
	if [ -f "$TMP_DIR/raw_music" ]; then
		# Standard single column numeric ascending sort (lowest score is best)
		sort -n "$TMP_DIR/raw_music" > "$TMP_DIR/sorted_music"
	fi
fi

# Compile and sort Other results
for domain in $OTHER_DOMAINS; do
	ips_file="$TMP_DIR/ips_$(echo "$domain" | tr '.' '_')"
	if [ -f "$ips_file" ]; then
		ips=$(cat "$ips_file")
		for ip in $ips; do
			outfile="$TMP_DIR/other_${domain}_${ip}"
			if [ -f "$outfile" ]; then
				data=$(cat "$outfile")
				c_ip=$(echo "$data" | cut -d'|' -f1)
				c_loss=$(echo "$data" | cut -d'|' -f2)
				c_avg=$(echo "$data" | cut -d'|' -f3)
				c_jit=$(echo "$data" | cut -d'|' -f4)
				c_https=$(echo "$data" | cut -d'|' -f5)
				c_code=$(echo "$data" | cut -d'|' -f6)
				c_ssl=$(echo "$data" | cut -d'|' -f7)
				
				# Zero-pad values to bypass BusyBox sort multicomponent floats sorting bugs
				fmt_loss=$(printf "%03d" "$c_loss" 2>/dev/null || echo "100")
				fmt_avg=$(printf "%08.2f" "$c_avg" 2>/dev/null || echo "9999.00")
				fmt_jit=$(printf "%08.2f" "$c_jit" 2>/dev/null || echo "9999.00")
				
				# Calculate sort score: (1 - c_https) * 1000000 + c_loss * 10000 + c_avg
				score_latency="$c_avg"
				[ "$score_latency" = "9999" ] && score_latency="9999.00"
				sort_score=$(awk "BEGIN {print (1 - $c_https) * 1000000 + $c_loss * 10000 + $score_latency}")
				fmt_score=$(printf "%015.2f" "$sort_score" 2>/dev/null || echo "9999999.00")
				
				c_geo=$(cat "$TMP_DIR/geo/$c_ip" 2>/dev/null || echo "Other")
				echo "$fmt_score $c_https $fmt_loss $fmt_avg $fmt_jit $c_ip $c_code $c_ssl $c_geo" >> "$TMP_DIR/raw_${domain}"
			fi
		done
		if [ -f "$TMP_DIR/raw_${domain}" ]; then
			# Standard single column numeric ascending sort (lowest score is best)
			sort -n "$TMP_DIR/raw_${domain}" > "$TMP_DIR/sorted_${domain}"
		fi
	fi
done

# Clear hosts file before writing
> "$HOSTS_FILE"

# 1. Apply Selected TV IPs to all expanded TV fallback domains
selected_tv_ips=""
if [ -f "$TMP_DIR/sorted_tv" ]; then
	selected_tv_ips=$(cat "$TMP_DIR/sorted_tv" | head -n 3 | while read -r r_score r_https r_loss r_avg r_jit r_ip r_code r_ssl r_geo; do
		if [ "$r_https" = "1" ]; then
			echo "$r_ip"
		fi
	done)
	
	if [ -n "$selected_tv_ips" ]; then
		expanded_tv=$(expand_tv_domains)
		for ip in $selected_tv_ips; do
			# Write to all expanded domains
			for d in $expanded_tv; do
				echo "$ip $d" >> "$HOSTS_FILE"
			done
			# Make sure configured domains are mapped as well
			for d in $DOMAINS; do
				if is_tv_domain "$d"; then
					echo "$ip $d" >> "$HOSTS_FILE"
				fi
			done
		done
	fi
fi

# 2. Apply Selected Music IPs to all expanded Music fallback domains
selected_music_ips=""
if [ -f "$TMP_DIR/sorted_music" ]; then
	selected_music_ips=$(cat "$TMP_DIR/sorted_music" | head -n 3 | while read -r r_score r_https r_loss r_avg r_jit r_ip r_code r_ssl r_geo; do
		if [ "$r_https" = "1" ]; then
			echo "$r_ip"
		fi
	done)
	
	if [ -n "$selected_music_ips" ]; then
		expanded_music=$(expand_music_domains)
		for ip in $selected_music_ips; do
			# Write to all expanded domains
			for d in $expanded_music; do
				echo "$ip $d" >> "$HOSTS_FILE"
			done
			# Make sure configured domains are mapped as well
			for d in $DOMAINS; do
				if is_music_domain "$d"; then
					echo "$ip $d" >> "$HOSTS_FILE"
				fi
			done
		done
	fi
fi

# 3. Apply Selected Other domains
for domain in $OTHER_DOMAINS; do
	if [ -f "$TMP_DIR/sorted_${domain}" ]; then
		cat "$TMP_DIR/sorted_${domain}" | head -n 3 | while read -r r_score r_https r_loss r_avg r_jit r_ip r_code r_ssl r_geo; do
			if [ "$r_https" = "1" ]; then
				echo "$r_ip $domain" >> "$HOSTS_FILE"
			fi
		done
	fi
done

# 4. Double-write to system /etc/hosts to support system resolution
echo "正在将优选规则同步至系统 /etc/hosts..."
sed -i '/# APPLE-CDN-OPT-START/,/# APPLE-CDN-OPT-END/d' /etc/hosts
if [ -s "$HOSTS_FILE" ]; then
	echo "# APPLE-CDN-OPT-START" >> /etc/hosts
	cat "$HOSTS_FILE" >> /etc/hosts
	echo "# APPLE-CDN-OPT-END" >> /etc/hosts
	echo "系统 /etc/hosts 同步写入成功。"
fi

# 5. Triple-write to OpenClash hosts configuration file to support Clash proxy DNS
if [ -d "/etc/openclash" ]; then
	echo "正在将优选规则同步至 OpenClash 专属 Hosts 配置..."
	mkdir -p /etc/openclash/custom
	touch /etc/openclash/custom/openclash_custom_hosts.list
	sed -i '/# APPLE-CDN-OPT-START/,/# APPLE-CDN-OPT-END/d' /etc/openclash/custom/openclash_custom_hosts.list
	if [ -s "$HOSTS_FILE" ]; then
		echo "# APPLE-CDN-OPT-START" >> /etc/openclash/custom/openclash_custom_hosts.list
		# Convert standard 'IP domain' format to Clash YAML ''domain': 'IP'' format (deduplicated, keep best IP)
		awk 'NF >= 2 && !seen[$2]++ {print "\047" $2 "\047: \047" $1 "\047"}' "$HOSTS_FILE" >> /etc/openclash/custom/openclash_custom_hosts.list
		echo "# APPLE-CDN-OPT-END" >> /etc/openclash/custom/openclash_custom_hosts.list
		echo "OpenClash 专属 Hosts 同步写入成功。"
	fi
fi

# Detect if Clash/OpenClash is running and print helpful configuration advice
if pgrep -f clash >/dev/null 2>&1; then
	echo "--------------------------------------------------------"
	echo "[提示] 检测到您的系统中正在运行 Clash/OpenClash 代理服务。"
	echo "[提示] 优选规则已自动同步写入 OpenClash 自定义 Hosts 文件中 (/etc/openclash/custom/openclash_custom_hosts.list)。"
	
	oc_hosts_en=$(uci -q get openclash.config.enable_hosts)
	if [ "$oc_hosts_en" != "1" ]; then
		echo "[警告] 检测到您的 OpenClash 自定义 Hosts 网页开关【尚未开启】！"
		echo "[提示] 请前往：OpenClash 后台 -> 本地规则 -> 自定义 Hosts"
		echo "[提示] 勾选【启用自定义 Hosts】并保存应用，否则直连流量将无法通过优选 IP。"
	else
		echo "[提示] 您的 OpenClash 自定义 Hosts 网页开关【已启用】。"
		echo "[提示] 每次跑完优化后，请在 OpenClash 后台点击【重载配置】以刷新缓存并载入最新 Hosts。"
	fi
	echo "--------------------------------------------------------"
fi

# Restart/Reload dnsmasq to apply updates
/etc/init.d/dnsmasq reload >/dev/null 2>&1

# Build the final JSON status representation for Web UI
json="{\"last_update\":\"$(date '+%Y-%m-%d %H:%M:%S')\",\"status\":\"success\",\"domains\":{"
first_domain=1

for domain in $DOMAINS; do
	if [ $first_domain -eq 1 ]; then
		first_domain=0
	else
		json="$json,"
	fi

	json="$json\"$domain\":{"

	# Match domain to its tested pool file
	sorted_file=""
	selected_ips=""
	if is_tv_domain "$domain"; then
		sorted_file="$TMP_DIR/sorted_tv"
		selected_ips=$selected_tv_ips
	elif is_music_domain "$domain"; then
		sorted_file="$TMP_DIR/sorted_music"
		selected_ips=$selected_music_ips
	else
		sorted_file="$TMP_DIR/sorted_${domain}"
		selected_ips=$(cat "$sorted_file" 2>/dev/null | head -n 3 | while read -r r_score r_https r_loss r_avg r_jit r_ip r_code r_ssl r_geo; do
			if [ "$r_https" = "1" ]; then
				echo "$r_ip"
			fi
		done | tr '\n' ' ')
	fi

	# Format selected list
	json_selected=""
	first_ip=1
	for ip in $selected_ips; do
		if [ $first_ip -eq 1 ]; then
			first_ip=0
		else
			json_selected="$json_selected,"
		fi
		json_selected="$json_selected\"$ip\""
	done
	json="$json\"selected\":[$json_selected],"

	# Format tested list
	json="$json\"tested\":["
	first_test=1
	if [ -f "$sorted_file" ]; then
		while read -r r_score r_https r_loss r_avg r_jit r_ip r_code r_ssl r_geo; do
			if [ $first_test -eq 1 ]; then
				first_test=0
			else
				json="$json,"
			fi
			# Clean up leading zeros for valid JSON numbers
			clean_loss=$(awk "BEGIN {print $r_loss + 0}")
			clean_avg=$(awk "BEGIN {print $r_avg + 0}")
			clean_jit=$(awk "BEGIN {print $r_jit + 0}")
			clean_ssl="9999"
			if [ -n "$r_ssl" ]; then
				clean_ssl=$(awk "BEGIN {print $r_ssl + 0}")
			fi
			json="$json{\"ip\":\"$r_ip\",\"loss\":$clean_loss,\"avg\":$clean_avg,\"jitter\":$clean_jit,\"https\":$r_https,\"code\":$r_code,\"ssl\":$clean_ssl,\"geo\":\"$r_geo\"}"
		done < "$sorted_file"
	fi
	json="$json]}"
done

json="$json}}"

# Write JSON to RESULT_JSON file
echo "$json" > "$RESULT_JSON"

# Clean up temp folder
rm -rf "$TMP_DIR"
echo "Apple CDN optimization completed successfully."
