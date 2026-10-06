#!/bin/sh
# Runs on the hypervisor from a systemd timer. Writes the thin-pool usage for
# node_exporter's textfile collector; the alerts at 80 and 90 percent read it.
# Usage: lvm-thin-metrics.sh <textfile directory>

set -eu

dir=$1
out="$dir/lvm_thin.prom"
tmp="$out.$$"

{
	echo '# HELP lvm_thin_pool_data_percent Thin pool data usage in percent.'
	echo '# TYPE lvm_thin_pool_data_percent gauge'
	echo '# HELP lvm_thin_pool_metadata_percent Thin pool metadata usage in percent.'
	echo '# TYPE lvm_thin_pool_metadata_percent gauge'
	echo '# HELP lvm_thin_pool_size_bytes Thin pool size in bytes.'
	echo '# TYPE lvm_thin_pool_size_bytes gauge'
	lvs --noheadings --units b --nosuffix --separator ';' \
		-o vg_name,lv_name,data_percent,metadata_percent,lv_size \
		-S 'segtype=thin-pool' | tr -d ' ' |
		while IFS=';' read -r vg lv data meta size; do
			echo "lvm_thin_pool_data_percent{vg=\"$vg\",lv=\"$lv\"} $data"
			echo "lvm_thin_pool_metadata_percent{vg=\"$vg\",lv=\"$lv\"} $meta"
			echo "lvm_thin_pool_size_bytes{vg=\"$vg\",lv=\"$lv\"} $size"
		done
} >"$tmp"

mv "$tmp" "$out"
