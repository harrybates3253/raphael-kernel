#!/usr/bin/env python3
"""让 msm pinctrl 对「不支持的 pinconf 参数」宽容处理。

现象（本 ROM + 本内核）：
  sm8150-pinctrl 3000000.pinctrl: pin_config_group_set op failed for group 122
  goodix_i2c 3-005d: Error applying setting, reverse things back
pinctrl_select_state() 里任意一个 group 配置失败会让整个 state 回滚，
goodix 指纹驱动的上电/复位时序因此失败 -> 能感知按压但录不进指纹。

做法：msm_config_group_set() 遇到 msm_config_reg() 不支持（或非法）的参数时
      跳过该参数继续处理其它参数，而不是整体返回错误。
"""
import sys

SRC = 'drivers/pinctrl/qcom/pinctrl-msm.c'
OLD = """\t\tret = msm_config_reg(pctrl, g, param, &mask, &bit);
\t\tif (ret < 0)
\t\t\treturn ret;
"""
NEW = """\t\tret = msm_config_reg(pctrl, g, param, &mask, &bit);
\t\tif (ret < 0) {
\t\t\t/* kit: 跳过该 pin 不支持的 pinconf 参数，避免整个 state 回滚 */
\t\t\tpr_debug("kit: skip pinconf param %u on group %u (rc=%d)\\n",
\t\t\t\tparam, group, ret);
\t\t\tcontinue;
\t\t}
"""


def main():
    src = open(SRC, encoding='utf-8', errors='replace').read()
    if 'kit: skip pinconf param' in src:
        print('[pinctrl] 已打过补丁，跳过')
        return 0
    if OLD not in src:
        print('[pinctrl] WARN 目标代码片段没找到，跳过', file=sys.stderr)
        return 1
    src = src.replace(OLD, NEW, 1)
    open(SRC, 'w', encoding='utf-8').write(src)
    print('[pinctrl] 已放宽 msm_config_group_set（不支持的参数跳过）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
