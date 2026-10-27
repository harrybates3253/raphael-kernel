#!/usr/bin/env python3
"""把树内 dtsi 里小米官方的 FOD/DC dim LUT 作为内置默认值注入 dsi_panel.c。

背景：这套移植 ROM 的 dtbo 面板节点没有 qcom,disp-fod-dim-lut / qcom,disp-dc-dim-lut，
      而本树的 dsi-staging 驱动强依赖它们（缺失时 alpha 恒 0）：
        · FOD 区域不做局部调亮 -> 指纹录入失败
        · 极低亮度下 dim layer 不生效 -> 各图层亮度不一致
用法：在源码树根目录执行 python3 patches/default-dim-lut.py
"""
import os
import re
import sys

DTSI_CANDIDATES = (
    'arch/arm64/boot/dts/qcom/dsi-panel-ss-fhd-ea8076-cmd.dtsi',
    'arch/arm64/boot/dts/qcom/dsi-panel-ss-fhd-ea8076-global-cmd.dtsi',
)
SRC = 'drivers/gpu/drm/msm/dsi-staging/dsi_panel.c'


def read_dtsi():
    for cand in DTSI_CANDIDATES:
        if not os.path.exists(cand):
            continue
        text = open(cand, encoding='utf-8', errors='replace').read()
        if 'disp-fod-dim-lut' in text:
            return cand, text
    return None, None


def parse_lut(text, prop):
    m = re.search(re.escape(prop) + r'\s*=\s*<(.*?)>;', text, re.S)
    if not m:
        return []
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    vals = []
    for tok in re.findall(r'\b\d+\b|0x[0-9a-fA-F]+', body):
        vals.append(int(tok, 16) if tok.lower().startswith('0x') else int(tok))
    return vals


def c_array(name, vals):
    rows = [', '.join(str(v) for v in vals[i:i + 8]) for i in range(0, len(vals), 8)]
    return 'static const u32 %s[] = {\n\t%s\n};\n' % (name, ',\n\t'.join(rows))


FN_FOD = 'dsi_panel_parse_fod_dim_lut'
FN_DC = 'dsi_panel_parse_dc_dim_lut'

PROP = {
    FN_FOD: 'qcom,disp-fod-dim-lut',
    FN_DC: 'qcom,disp-dc-dim-lut',
}
FIELD = {
    FN_FOD: ('fod_dim_lut', 'fod_dim_lut_len', 'kit_dsi_fod_lut_default'),
    FN_DC: ('dc_dim_lut', 'dc_dim_lut_len', 'kit_dsi_dc_lut_default'),
}


def make_body(fn):
    prop = PROP[fn]
    lut, lut_len, table = FIELD[fn]
    return (
        'static int %(fn)s(struct dsi_panel *panel,\n'
        '\t\tstruct dsi_parser_utils *utils)\n'
        '{\n'
        '\tconst char *prop_name = "%(prop)s";\n'
        '\tunsigned int i;\n'
        '\tu32 *array = NULL;\n'
        '\tint count, rc = 0;\n'
        '\n'
        '\tcount = utils->count_u32_elems(utils->data, prop_name);\n'
        '\tif (count <= 0 || count %% BRIGHTNESS_ALPHA_PAIR_LEN) {\n'
        '\t\tpr_warn("[%%s] %%s missing in dt (count=%%d), using builtin default\\n",\n'
        '\t\t\tpanel->name, prop_name, count);\n'
        '\t\tcount = ARRAY_SIZE(%(table)s);\n'
        '\t\tarray = kmemdup(%(table)s, sizeof(%(table)s), GFP_KERNEL);\n'
        '\t\tif (!array)\n'
        '\t\t\treturn -ENOMEM;\n'
        '\t} else {\n'
        '\t\tarray = kcalloc(count, sizeof(u32), GFP_KERNEL);\n'
        '\t\tif (!array)\n'
        '\t\t\treturn -ENOMEM;\n'
        '\t\trc = utils->read_u32_array(utils->data, prop_name, array, count);\n'
        '\t\tif (rc) {\n'
        '\t\t\tkfree(array);\n'
        '\t\t\treturn rc;\n'
        '\t\t}\n'
        '\t}\n'
        '\n'
        '\tcount /= BRIGHTNESS_ALPHA_PAIR_LEN;\n'
        '\tpanel->%(lut)s = kcalloc(count, sizeof(*panel->%(lut)s), GFP_KERNEL);\n'
        '\tif (!panel->%(lut)s) {\n'
        '\t\tkfree(array);\n'
        '\t\treturn -ENOMEM;\n'
        '\t}\n'
        '\tpanel->%(lut_len)s = count;\n'
        '\tfor (i = 0; i < count; i++) {\n'
        '\t\tpanel->%(lut)s[i].brightness = array[i * BRIGHTNESS_ALPHA_PAIR_LEN + 0];\n'
        '\t\tpanel->%(lut)s[i].alpha = array[i * BRIGHTNESS_ALPHA_PAIR_LEN + 1];\n'
        '\t}\n'
        '\tkfree(array);\n'
        '\tpr_info("[%%s] %%s loaded %%d entries\\n", panel->name, prop_name, count);\n'
        '\treturn 0;\n'
        '}\n'
    ) % dict(fn=fn, prop=prop, table=table, lut=lut, lut_len=lut_len)


def replace_fn(src, fn):
    sig = 'static int %s(struct dsi_panel *panel,' % fn
    start = src.index(sig)
    end = src.index('\n}\n', start) + 3
    return src[:start] + make_body(fn) + src[end:]


def main():
    dtsi_path, dtsi = read_dtsi()
    if dtsi is None:
        print('[lut] WARN 没找到含 disp-fod-dim-lut 的面板 dtsi，跳过', file=sys.stderr)
        return 1
    fod = parse_lut(dtsi, 'qcom,disp-fod-dim-lut')
    dc = parse_lut(dtsi, 'qcom,disp-dc-dim-lut')
    if not fod:
        print('[lut] WARN fod lut 解析为空，跳过', file=sys.stderr)
        return 1

    src = open(SRC, encoding='utf-8', errors='replace').read()
    if 'kit_dsi_fod_lut_default' in src:
        print('[lut] 已打过补丁，跳过')
        return 0
    if 'BRIGHTNESS_ALPHA_PAIR_LEN' not in src:
        print('[lut] WARN 源文件里没有 BRIGHTNESS_ALPHA_PAIR_LEN，跳过', file=sys.stderr)
        return 1

    helpers = ('/* ---- kit: 内置 dim LUT 默认值（dtbo 未提供时使用，取自 %s）---- */\n' % dtsi_path
               + c_array('kit_dsi_fod_lut_default', fod)
               + c_array('kit_dsi_dc_lut_default', dc))
    anchor = 'static int %s(struct dsi_panel *panel,' % FN_FOD
    src = src.replace(anchor, helpers + '\n' + anchor, 1)

    src = replace_fn(src, FN_FOD)
    if 'static int %s(struct dsi_panel *panel,' % FN_DC in src and dc:
        src = replace_fn(src, FN_DC)

    open(SRC, 'w', encoding='utf-8').write(src)
    print('[lut] 已注入：fod %d 元素 / dc %d 元素（来源 %s）' % (len(fod), len(dc), dtsi_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
