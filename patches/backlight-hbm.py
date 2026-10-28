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


if __name__ == '__main__':
    sys.exit(main())
