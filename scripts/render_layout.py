# KLayout batch script: render a GDS or DEF to PNG with the sky130A layer colours.
#
#   klayout -b -r scripts/render_layout.py \
#       -rd in=final/gds/riscv_core.gds -rd out=results/layout.png \
#       -rd pdk=$HOME/.ciel/sky130A [-rd width=2400] [-rd hide=areaid,nwell] [-rd list=1]
#       [-rd box=x1,y1,x2,y2]   (zoom window in µm)
#
# For DEF input the sky130 tech LEF + cell LEFs and the LEF/DEF layer map from the
# PDK are loaded so the DEF layers get their GDS layer numbers and colours.
# 'hide' is a comma-separated list of substrings; layers whose name/source
# contains one of them are hidden (e.g. "fill" hides metal fill shapes).
import glob
import os

import pya

inp = globals().get("in")
out = globals().get("out")
pdk = globals().get("pdk")
width = int(globals().get("width", "2400"))
hide = [h for h in globals().get("hide", "").split(",") if h]
list_only = globals().get("list", "0") == "1"
zoom = globals().get("box", "")  # optional "x1,y1,x2,y2" in µm

tech = os.path.join(pdk, "libs.tech", "klayout", "tech")
lyp = os.path.join(tech, "sky130A.lyp")

opt = pya.LoadLayoutOptions()
if inp.lower().endswith(".def"):
    cfg = opt.lefdef_config
    ref = os.path.join(pdk, "libs.ref")
    cfg.lef_files = [
        glob.glob(os.path.join(ref, "sky130_fd_sc_hd", "techlef", "sky130_fd_sc_hd__nom.tlef"))[0],
        os.path.join(ref, "sky130_fd_sc_hd", "lef", "sky130_fd_sc_hd.lef"),
        os.path.join(ref, "sky130_fd_sc_hd", "lef", "sky130_ef_sc_hd.lef"),
    ]
    cfg.map_file = os.path.join(tech, "sky130A.map")
    # use the real standard-cell layouts (not the empty LEF abstracts) for placed cells
    cfg.macro_layout_files = [os.path.join(ref, "sky130_fd_sc_hd", "gds", "sky130_fd_sc_hd.gds")]
    cfg.macro_resolution_mode = 2
    cfg.read_lef_with_def = False
    cfg.produce_cell_outlines = False
    for attr in ("produce_labels", "produce_lef_labels", "produce_obstructions", "produce_blockages",
                 "produce_placement_blockages", "produce_regions"):
        if hasattr(cfg, attr):
            setattr(cfg, attr, False)
    opt.lefdef_config = cfg

view = pya.LayoutView()
view.load_layout(inp, opt, True)
view.load_layer_props(lyp)
view.set_config("background-color", "#ffffff")
view.set_config("grid-visible", "false")
view.set_config("text-visible", "false")
view.set_config("cell-box-visible", "false")
view.max_hier()

layout = view.cellview(0).layout()
used = {(layout.get_info(i).layer, layout.get_info(i).datatype) for i in layout.layer_indexes()
        if not layout.top_cell().bbox_per_layer(i).empty()}

it = view.begin_layers()
while not it.at_end():
    lp = it.current()
    key = (lp.source_layer, lp.source_datatype)
    label = f"{lp.name} {lp.source}"
    if list_only and key in used:
        print(label)
    if hide and any(h in label for h in hide):
        lp.visible = False
        view.set_layer_properties(it, lp)
    it.next()

if not list_only:
    if zoom:
        x1, y1, x2, y2 = (float(v) for v in zoom.split(","))
        view.zoom_box(pya.DBox(x1, y1, x2, y2))
    else:
        view.zoom_fit()
    bbox = view.box()
    height = max(1, int(width * bbox.height() / bbox.width()))
    view.save_image(out, width, height)
    print(f"wrote {out} ({width}x{height})")
