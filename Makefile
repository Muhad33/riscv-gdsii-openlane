# -----------------------------------------------------------------------------
# riscv-gdsii-openlane: RV32I core, RTL -> GDSII with LibreLane + sky130
#
# Simulation (Windows or Linux; needs python + iverilog):
#   make sim              unit tests + all asm/*.s + 50 random programs on rtl/riscv_core.v
#   make test NAME=gcd    one program
#   make random N=200     N random programs only (SEED=1)
#   make sim-ref          same programs on the original design (ref/), for A/B comparison
#
# Physical design (Linux / WSL2 with the LibreLane nix-shell, see README; the
# project path must not contain spaces -> scripts/wsl_mount.sh):
#   make lint             Verilator -Wall + Yosys latch / loop / async-reset checks
#   make flow             full RTL -> GDSII flow at PERIOD (default 20 ns) -> flow/runs/p20
#   make sweep            clock sweep 25/20/17.5/15/12.5/10 ns + results/clock_sweep.{md,png}
#   make final            copy signoff views + reports of RUN into final/
#   make gate             gate-level simulation of final/netlist (fibonacci, hazard_test)
#   make render           results/layout.png + flow-stage images
#   make ppa              results/ppa_summary.md
#   make counter          8-bit counter smoke test (examples/counter)
#
#   make clean            remove sim/ and hex/ outputs (flow/runs is kept; delete by hand)
# -----------------------------------------------------------------------------

ifeq ($(OS),Windows_NT)
  PYTHON ?= python
else
  PYTHON ?= python3
endif
N      ?= 50
SEED   ?= 1
NAME   ?=
PERIOD ?= 20
RUN    ?= flow/runs/p$(subst .,_,$(PERIOD))
LL     := bash scripts/ll.sh

.PHONY: sim test random sim-ref lint flow sweep final gate render ppa counter clean

sim:
	$(PYTHON) scripts/run_tests.py --units --random $(N) --seed $(SEED)

test:
	$(PYTHON) scripts/run_tests.py --name $(NAME)

random:
	$(PYTHON) scripts/run_tests.py --name __none__ --random $(N) --seed $(SEED)

sim-ref:
	$(PYTHON) scripts/run_tests.py --ref --random $(N) --seed $(SEED)

lint:
	$(LL) bash scripts/lint.sh

flow:
	$(LL) librelane --run-tag p$(subst .,_,$(PERIOD)) --overwrite -c CLOCK_PERIOD=$(PERIOD) flow/config.json

sweep:
	bash scripts/sweep.sh
	$(PYTHON) scripts/sweep_report.py

final:
	bash scripts/collect_final.sh $(RUN)

gate:
	$(LL) bash scripts/gate_sim.sh

render:
	$(LL) bash scripts/render_all.sh $(RUN)

ppa:
	$(LL) python3 scripts/ppa_summary.py $(RUN)

counter:
	$(LL) librelane --run-tag phase1 --overwrite examples/counter/config.json

clean:
	$(PYTHON) -c "import shutil; [shutil.rmtree(d, ignore_errors=True) for d in ('sim', 'hex')]"
