#!/usr/bin/env python3
"""给 DRM connector 增加 Xiaomi 的 disp_param sysfs 节点。

背景：这套 ROM 的指纹 HAL（fingerprint.goodix_fod.so）会 open/write
      /sys/class/drm/card0-DSI-1/disp_param，写入 8 字节十六进制字符串来请求
      HBM / FOD 高亮（0x20000 = HBM_FOD_ON，0xE0000 = HBM_FOD_OFF，0xF0000 = HBM_OFF）。
      我们这棵树没有该节点 -> HAL 报 "hbm fd : open failed!" -> 指纹区域不点亮 -> 录不进指纹。

实现：在 connector 的 sysfs 目录下注册 disp_param，解析十六进制，映射到面板 HBM 状态；
      其余命令（ACL/DIMMING 等）先记录到 dmesg，便于后续按真实写入值继续实现。
"""
import sys

SRC = 'drivers/gpu/drm/msm/sde/sde_connector.c'

HELPERS = r'''
/* ---- kit: Xiaomi disp_param sysfs ---- */
#define KIT_DISPPARAM_HBM_ON		0x10000
#define KIT_DISPPARAM_HBM_FOD_ON	0x20000
#define KIT_DISPPARAM_HBM_FOD_OFF	0xE0000
#define KIT_DISPPARAM_HBM_OFF		0xF0000

static ssize_t disp_param_show(struct device *dev,
		struct device_attribute *attr, char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "0x0\n");
}

static ssize_t disp_param_store(struct device *dev,
		struct device_attribute *attr, const char *buf, size_t count)
{
	struct drm_connector *connector = dev_get_drvdata(dev);
	struct sde_connector *c_conn;
	struct dsi_panel *panel;
	unsigned long val = 0;
	int rc;

	if (!connector) {
		pr_err("kit disp_param: no connector\n");
		return -ENODEV;
	}

	c_conn = to_sde_connector(connector);
	panel = sde_connector_panel(c_conn);

	rc = kstrtoul(buf, 16, &val);
	if (rc)
		rc = kstrtoul(buf, 0, &val);
	if (rc) {
		pr_err("kit disp_param: bad input '%s'\n", buf);
		return -EINVAL;
	}

	pr_info("kit disp_param: 0x%lx\n", val);

	if (!panel)
		return count;

	switch (val) {
	case KIT_DISPPARAM_HBM_ON:
	case KIT_DISPPARAM_HBM_FOD_ON:
		dsi_panel_set_fod_hbm(panel, true);
		dsi_panel_set_fod_ui(panel, true);
		break;
	case KIT_DISPPARAM_HBM_FOD_OFF:
	case KIT_DISPPARAM_HBM_OFF:
		dsi_panel_set_fod_hbm(panel, false);
		dsi_panel_set_fod_ui(panel, false);
		break;
	default:
		/* ACL / DIMMING / ELVSS 等先只记录，等看到真实写入值再实现 */
		break;
	}

	return count;
}

static DEVICE_ATTR(disp_param, 0644, disp_param_show, disp_param_store);
/* ---- kit end ---- */

'''

OLD_LATE = '''static int sde_connector_late_register(struct drm_connector *connector)
{
	return sde_connector_init_debugfs(connector);
}'''

NEW_LATE = '''static int sde_connector_late_register(struct drm_connector *connector)
{
	int rc = sde_connector_init_debugfs(connector);

	if (connector->kdev) {
		dev_set_drvdata(connector->kdev, connector);
		device_create_file(connector->kdev, &dev_attr_disp_param);
	}

	return rc;
}'''


def main():
    src = open(SRC, encoding='utf-8', errors='replace').read()
    if 'kit disp_param' in src:
        print('[disp_param] 已打过补丁，跳过')
        return 0
    if OLD_LATE not in src:
        print('[disp_param] WARN 找不到 sde_connector_late_register，跳过', file=sys.stderr)
        return 1
    if 'dsi_panel_set_fod_hbm' not in src:
        print('[disp_param] WARN 树里没有 dsi_panel_set_fod_hbm，跳过', file=sys.stderr)
        return 1

    src = src.replace(OLD_LATE, HELPERS + NEW_LATE, 1)
    open(SRC, 'w', encoding='utf-8').write(src)
    print('[disp_param] 已注入 disp_param sysfs（HBM/FOD 映射 + 全量日志）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
