#!/usr/bin/env python3
"""让 backlight sysfs 支持 HBM 区间（0..4095），使指纹 HAL 的 HBM 请求生效。

现状（本树 + 本 ROM 的 dtbo）：
  /sys/class/backlight/panel0-backlight/max_brightness = 2047
  写 4095 会被 clamp 回 2047
  而 dsi_display_set_backlight() 里明明有 "bl_lvl==4095 -> hbm_mode=1 + apply" 的逻辑，
  永远走不到 -> 光学指纹取不到高亮画面 -> 录入失败。

做法：
  1) sde_backlight_setup(): props.max_brightness 抬到 4095（HBM 上限）
  2) sde_backlight_device_update_status(): 亮度 > 面板正常上限时，
     直接以 4095 调用 set_backlight（触发 hbm_mode），而不是 clamp 掉。
"""
import sys

SRC = 'drivers/gpu/drm/msm/sde/sde_connector.c'

OLD_SETUP = """	props.max_brightness = bl_config->brightness_max_level;"""
NEW_SETUP = """	/* kit: 抬到 HBM 上限，指纹 HAL 靠写 4095 触发高亮 */
	props.max_brightness = bl_config->brightness_max_level >= 4095 ?
			bl_config->brightness_max_level : 4095;"""

OLD_CLAMP = """	if (brightness > display->panel->bl_config.brightness_max_level)
		brightness = display->panel->bl_config.brightness_max_level;"""
NEW_CLAMP = """	if (brightness > display->panel->bl_config.brightness_max_level) {
		/* kit: HBM 区间（>正常上限）——直接按 4095 下发，触发面板 HBM */
		if (c_conn->allow_bl_update && c_conn->ops.set_backlight) {
			event.type = DRM_EVENT_SYS_BACKLIGHT;
			event.length = sizeof(u32);
			msm_mode_object_event_notify(&c_conn->base.base,
					c_conn->base.dev, &event, (u8 *)&brightness);
			rc = c_conn->ops.set_backlight(&c_conn->base,
					c_conn->display, 4095);
			c_conn->unset_bl_level = 0;
		} else {
			c_conn->unset_bl_level = 4095;
		}
		return rc;
	}"""


def main():
    src = open(SRC, encoding='utf-8', errors='replace').read()
    if 'kit: 抬到 HBM 上限' in src:
        print('[hbm] 已打过补丁，跳过')
        return 0
    if OLD_SETUP not in src or OLD_CLAMP not in src:
        print('[hbm] WARN 目标代码片段没找到，跳过', file=sys.stderr)
        return 1
    src = src.replace(OLD_SETUP, NEW_SETUP, 1)
    src = src.replace(OLD_CLAMP, NEW_CLAMP, 1)
    open(SRC, 'w', encoding='utf-8').write(src)
    print('[hbm] 已开启 backlight HBM 区间（max 4095，>上限走 HBM）')
    return 0




# ---- 第二步：修正 dsi_display_set_backlight 里的 HBM 判定顺序 ----
# 原逻辑：先 dsi_panel_set_backlight(bl_temp) 再判断 bl_config.bl_level <= 2047，
# 而 bl_temp 在 scaling 后往往已经等于 4095，条件永远不成立 -> HBM 从不生效。
DSI = 'drivers/gpu/drm/msm/dsi-staging/dsi_display.c'

DSI_OLD = """	rc = dsi_panel_set_backlight(panel, (u32)bl_temp);
	if (rc)
		pr_err("unable to set backlight\n");

	if (bl_lvl == 4095 && panel->bl_config.bl_level <= 2047)
	{
		panel->hbm_mode = 1;
		rc = dsi_panel_apply_hbm_mode(panel);
	}
	else if (bl_lvl <= 2047 && panel->bl_config.bl_level == 4095)
	{
		panel->hbm_mode = 0;
		rc = dsi_panel_apply_hbm_mode(panel);
	}
"""

DSI_NEW = """	/* kit: 先按 bl_lvl 判定 HBM，再下发普通背光（原顺序必然判失败） */
	if (bl_lvl >= 4095) {
		if (bl_temp > panel->bl_config.bl_max_level)
			bl_temp = panel->bl_config.bl_max_level;
		rc = dsi_panel_set_backlight(panel, (u32)bl_temp);
		if (rc)
			pr_err("unable to set backlight\n");
		if (!panel->hbm_mode) {
			panel->hbm_mode = 1;
			pr_info("kit: HBM ON (bl_lvl=%u)\n", bl_lvl);
			rc = dsi_panel_apply_hbm_mode(panel);
			if (rc)
				pr_err("kit: hbm on failed rc=%d\n", rc);
		}
	} else {
		if (panel->hbm_mode) {
			panel->hbm_mode = 0;
			pr_info("kit: HBM OFF (bl_lvl=%u)\n", bl_lvl);
			rc = dsi_panel_apply_hbm_mode(panel);
		}
		rc = dsi_panel_set_backlight(panel, (u32)bl_temp);
		if (rc)
			pr_err("unable to set backlight\n");
	}
"""


def patch_dsi():
    """按索引替换 HBM 判定块（不依赖字面匹配，避免缩进/换行差异导致漏改）。"""
    import os
    if not os.path.exists(DSI):
        print('[hbm] 没有 dsi_display.c，跳过第二步', file=sys.stderr)
        return 1
    src = open(DSI, encoding='utf-8', errors='replace').read()
    if 'kit: 先按 bl_lvl 判定 HBM' in src:
        print('[hbm] dsi_display 已打过补丁')
        return 0

    anchor = 'rc = dsi_panel_set_backlight(panel, (u32)bl_temp);'
    tail = '\tpanel->bl_config.bl_level = bl_lvl;'
    i = src.find(anchor)
    j = src.find(tail, i)
    if i < 0 or j < 0:
        print('[hbm] WARN dsi_display 里找不到 HBM 块，跳过第二步', file=sys.stderr)
        return 1

    # 从 anchor 所在行行首开始替换，到 bl_level 赋值行之前为止
    line_start = src.rfind('\n', 0, i) + 1
    new_block = (
        '\t/* kit: 先按 bl_lvl 判定 HBM，再下发普通背光（原顺序必然判失败） */\n'
        '\tif (bl_lvl >= 4095) {\n'
        '\t\tif (bl_temp > panel->bl_config.bl_max_level)\n'
        '\t\t\tbl_temp = panel->bl_config.bl_max_level;\n'
        '\t\trc = dsi_panel_set_backlight(panel, (u32)bl_temp);\n'
        '\t\tif (rc)\n'
        '\t\t\tpr_err("unable to set backlight\\n");\n'
        '\t\tif (!panel->hbm_mode) {\n'
        '\t\t\tpanel->hbm_mode = 1;\n'
        '\t\t\tpr_info("kit: HBM ON (bl_lvl=%u)\\n", bl_lvl);\n'
        '\t\t\trc = dsi_panel_apply_hbm_mode(panel);\n'
        '\t\t\tif (rc)\n'
        '\t\t\t\tpr_err("kit: hbm on failed rc=%d\\n", rc);\n'
        '\t\t}\n'
        '\t} else {\n'
        '\t\tif (panel->hbm_mode) {\n'
        '\t\t\tpanel->hbm_mode = 0;\n'
        '\t\t\tpr_info("kit: HBM OFF (bl_lvl=%u)\\n", bl_lvl);\n'
        '\t\t\trc = dsi_panel_apply_hbm_mode(panel);\n'
        '\t\t}\n'
        '\t\trc = dsi_panel_set_backlight(panel, (u32)bl_temp);\n'
        '\t\tif (rc)\n'
        '\t\t\tpr_err("unable to set backlight\\n");\n'
        '\t}\n\n'
    )
    src = src[:line_start] + new_block + src[j:]
    open(DSI, 'w', encoding='utf-8').write(src)
    print('[hbm] 已修正 dsi_display_set_backlight 的 HBM 判定顺序')
    return 0


if __name__ == '__main__':
    rc = main()
    patch_dsi()
    sys.exit(rc)
