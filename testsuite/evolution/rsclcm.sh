#!/usr/bin/env bash
set -euo pipefail

# make_runs.sh
# Build a YREC .nml1 run block from a template that includes a target core mass from an existing .first file and an evolution run
# Requirements: bash, grep, sed, awk, python3 in PATH
#
# Usage:
#   rsclcm.sh -t Test_m1000_feh0_base_TAHB_template.nml1 -f output/Test_m1000_feh0_base_HeIgnite.last -n Test_m1000_feh0_base_HeIgnite.nml2 -d ../../input/models/zahb/100mSOLpreZAHB.last -s 0.05 -o Test_m1000_feh0_base_TAHB.nml1
# Options:
#   -t  path to template .nml1, which will be filled in with core mass rescalings in steps of size STEP solar masses
#   -f  path to .first file, which is the file that has the target core mass
#   -n  path to the .nml2 file that is used to determine how to define the core mass. it should be the .nml2 file that was used to create the .first file.
#   -s  step size in core mass (float) (recommended 0.05)
#   -d  path to ZAHB seed file. if the mass is not the same as the total mass for the .first file, will need to add an envelope rescaling. !!! this is not currently automated ad would need to be put in by hand by the user to the template file after it is made from this script.
#   -o  output .nml1 (default: <template basename>.filled.nml1), which is the .nml1 file that will be made to do the rescaling and evolution run
#
# The script extracts these values from the template and leaves other things in place:
#   From the (1) block: CMIXLA(1), RSCLX(1), RSCLZ(1), NMODLS(1)
#   From the (NRUN) block: XENV0A(NRUN), ZENV0A(NRUN), CMIXLA(NRUN), END_YCEN(NRUN), NMODLS(NRUN) if present
#
# It then replaces the template region starting at the first line beginning with "NUMRUN ="
# and ending at the line containing "END_YCEN(NRUN)" (inclusive).

rescale_py="python3 find_core.py"
rsclcm_first=0
count_evolve_in_numrun=1
template=""
firstfile=""
step=""
outfile=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) template="$2"; shift 2;;
    -f) firstfile="$2"; shift 2;;
    -s) step="$2"; shift 2;;
    -o) outfile="$2"; shift 2;;
    -n) nml2="$2"; shift 2;;
    -d) seedfile="$2"; shift 2;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0;;
    *) die "unknown argument: $1";;
  esac
done

[[ -n "$template" && -f "$template" ]] || die "template file missing: -t <template.nml1>"
[[ -n "$seedfile" && -f "$seedfile" ]] || die "seed file missing: -t <template.nml1>"
[[ -n "$nml2" && -f "$nml2" ]] || die "nml2 file missing: -t <model.nml2>"
[[ -n "$firstfile" && -f "$firstfile" ]] || die ".first file missing: -f <model.first>"
[[ -n "$step" ]] || die "step size missing: -s <float>"
outfile="${outfile:-$(basename "${template%.*}").filled.nml1}"

# 1) Get target core mass from rescale.py (must print a single float to stdout)
target_core_mass="$($rescale_py --first "$firstfile" --nml2 "$nml2" | tail -n1 | tr -d '[:space:]')"
[[ "$target_core_mass" =~ ^-?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] || die "rescale.py did not return a float: '$target_core_mass'"

# 2) Get seed mass
seed_core_mass="$($rescale_py --first "$seedfile" --nml2 "$nml2" | tail -n1 | tr -d '[:space:]')"
[[ "$seed_core_mass" =~ ^-?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] || die "get_seed_mass.sh did not return a float: '$seed_core_mass'"

# 3) Compute number of rescale runs and the goal masses
read -r rescale_runs goals_json <<EOF
$(python3 - <<PY
import json, math
t = float("$target_core_mass")
s0 = float("$seed_core_mass")
step = float("$step")
if step <= 0:
    raise SystemExit("Step must be > 0")
delta = max(0.0, t - s0)
runs = 1 if delta == 0 else int(math.ceil(delta/step))
# Build targets for each rescale run
goals = []
for i in range(1, runs+1):
    goals.append(min(s0 + i*step, t))
print(runs, json.dumps(goals))
PY
)
EOF

# 4) Extract constants from the template
extract() {
  local pat="$1"
  # prints first captured value after '=' up to a comment or end of line
  sed -n -E "s/^[[:space:]]*${pat}[[:space:]]*=[[:space:]]*([^ !#;]+).*$/\\1/p" "$template" | head -n1
}

CMIXLA1="$(extract 'CMIXLA\(1\)')"
RSCLX1="$(extract 'RSCLX\(1\)')"
RSCLZ1="$(extract 'RSCLZ\(1\)')"
NMODLS1="$(extract 'NMODLS\(1\)')"

XENVN="$(extract 'XENV0A\(NRUN\)')"
ZENVN="$(extract 'ZENV0A\(NRUN\)')"
CMIXLAN="$(extract 'CMIXLA\(NRUN\)')"
ENDYCENN="$(extract 'END_YCEN\(NRUN\)')"
NMODLSN="$(extract 'NMODLS\(NRUN\)')"

# # Basic sanity with defaults if missing
# : "${CMIXLA1:=1.68}"
# : "${RSCLX1:=0.703}"
# : "${RSCLZ1:=0.019}"
# : "${NMODLS1:=10}"
# : "${XENVN:=0.703}"
# : "${ZENVN:=0.019}"
# : "${CMIXLAN:=$CMIXLA1}"
# : "${ENDYCENN:=0.0004}"
# : "${NMODLSN:=1000000}"

# 5) Build the generated block
{
    # Decide NUMRUN value


  if [[ "$count_evolve_in_numrun" -eq 1 ]]; then
    echo " NUMRUN = $((rescale_runs + 1))"
  else
    echo " NUMRUN = ${rescale_runs}"
  fi
  echo

  # First rescale run (i=1)
  i=1
  echo " KINDRN($i) = 2 ! 1 = evolve 2= rescale (zero timestep,MS or CHeB); 3 = rescale and evolve (pre-MS, no zero timestep)"
  echo " LFIRST($i) = .TRUE. ! T = use stored starting model F = use result of prior run"
  echo " CMIXLA($i) = ${CMIXLA1}"
  echo " RSCLX($i) = ${RSCLX1}"
  echo " RSCLZ($i) = ${RSCLZ1}"
  if [[ "$rsclcm_first" -eq 1 ]]; then
    # Set explicit target for the first step if requested
    first_goal="$(python3 - <<PY
import json; print(${goals_json}[0])
PY
)"
    echo " RSCLM($i) = -1 ! If positive, rescale to this mass (Msun)"
    echo " RSCLCM($i) = ${first_goal} ! If positive, rescale to this core mass (CHeB only)"
  fi
  echo " NMODLS($i) = ${NMODLS1}"
  echo

  # Subsequent rescale runs (i=2..rescale_runs)
  if [[ "$rescale_runs" -ge 1 ]]; then
      export GOALS_JSON="$goals_json"
      export CMIXLA1 RSCLX1 RSCLZ1 NMODLS1
    python3 - <<'PY'
import json, os
goals = json.loads(os.environ['GOALS_JSON'])
CMIXLA1=os.environ['CMIXLA1']; RSCLX1=os.environ['RSCLX1']; RSCLZ1=os.environ['RSCLZ1']; NMODLS1=os.environ['NMODLS1']
for idx, goal in enumerate(goals, start=1):
    print(f" KINDRN({idx}) = 2 ! rescale")
    print(f" LFIRST({idx}) = .FALSE.")
    print(f" CMIXLA({idx}) = {CMIXLA1}")
    print(f" RSCLX({idx}) = {RSCLX1}")
    print(f" RSCLZ({idx}) = {RSCLZ1}")
    print(f" RSCLM({idx}) = -1 ! If positive, rescale to this mass (Msun)")
    print(f" RSCLCM({idx}) = {goal} ! If positive, rescale to this core mass (CHeB only)")
    print(f" NMODLS({idx}) = {NMODLS1}\n")
PY
  fi

  # Final evolve run
  evolven=$((rescale_runs + 1))
  echo " KINDRN(${evolven}) = 1"
  echo " LFIRST(${evolven}) = .FALSE."
  echo " NMODLS(${evolven}) = ${NMODLSN}"
  echo " XENV0A(${evolven}) = ${XENVN} ! Envelope abundance label"
  echo " ZENV0A(${evolven}) = ${ZENVN}"
  echo " CMIXLA(${evolven}) = ${CMIXLAN}"
  echo " LSENV0A(${evolven}) = .TRUE. ! If true, adjust outer fitting point mass location."
  echo " SENV0A(${evolven}) = -1.0D-4 ! Log of fractional envelope fitting point mass. 1e-4 standard, 1e-7 thin    "
  echo " END_YCEN(${evolven}) = ${ENDYCENN} ! Run stops if NMODLS(I) is reached or this central helium is reached (TAHB)"
} > .__gen_block.nml1

# 6) Splice into template: replace from first "NUMRUN =" line through "END_YCEN(NRUN)" line (inclusive)
#    Then write to outfile.
# 6) splice generated block into template without removing other content
sed -E "/^[[:space:]]*NUMRUN[[:space:]]*=/,/END_YCEN\((NRUN|[0-9]+)\)/{
/^[[:space:]]*NUMRUN[[:space:]]*=/{
    r .__gen_block.nml1
}
d
}" "$template" > "$outfile"

rm -f .__gen_block.nml1

echo "Seed core mass   : ${seed_core_mass}"
echo "Target core mass : ${target_core_mass}"
echo "Step size        : ${step}"
echo "Rescale runs     : ${rescale_runs}"
echo "Wrote            : ${outfile}"
