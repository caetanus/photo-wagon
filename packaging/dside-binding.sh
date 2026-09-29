#!/bin/sh
# Generates and builds DSide's Qt Quick binding for the Qt that pkg-config finds:
#
#   packaging/dside-binding.sh <dside-checkout>
#
# → <dside>/generated/qt-<minor>/cxx-quick and <dside>/.build/qt-<minor>-cxx-quick/{libbinding_ldc2.a,libshims.a}
#
# The same steps DSide's reggae build takes for this one binding (reggae/qtd_build.d:
# qtdBinding, qtdBindLib), without configuring its whole test matrix. The shipped spec names
# one machine's Qt, so the spec xiboca reads is derived for this one: the private-header
# directories of every module, the QML type registry re-rooted under this Qt's qml dir.
set -eu
DSIDE=$(cd "$1" && pwd)
MODS="Qt6Quick Qt6QmlModels Qt6Qml Qt6Gui Qt6Core"
MINOR=$(pkg-config --modversion Qt6Core | cut -d. -f1-2)
GEN=$DSIDE/generated/qt-$MINOR/cxx-quick
BDIR=$DSIDE/.build/qt-$MINOR-cxx-quick
CFLAGS=$(pkg-config --cflags $MODS)
mkdir -p "$BDIR"

# -I<inc>/QtX/<version> and -I<inc>/QtX/<version>/QtX for every module that has private headers
PRIV=""
for f in $CFLAGS; do
    case "$f" in -I*/Qt*) ;; *) continue ;; esac
    d=${f#-I}
    mod=$(basename "$d")
    for v in "$d"/*/; do
        v=${v%/}
        [ -d "$v/$mod/private" ] && PRIV="$PRIV -I$v -I$v/$mod"
    done
done
[ -n "$PRIV" ] || { echo "dside-binding: no Qt private headers found (install the *-private-dev packages)" >&2; exit 1; }

QML_DIR=$(qtpaths6 --query QT_INSTALL_QML 2>/dev/null || qmake6 -query QT_INSTALL_QML 2>/dev/null \
          || qtpaths --query QT_INSTALL_QML 2>/dev/null || qmake -query QT_INSTALL_QML)
python3 - "$DSIDE/generator/spec_cxx_quick.json" "$BDIR/spec.derived.json" "$GEN" "$QML_DIR" $PRIV <<'EOF'
import json, os, sys
spec, out, gen, qml = sys.argv[1:5]
priv = [p[2:] for p in sys.argv[5:]]
j = json.load(open(spec))
j["out_dir"] = gen
j["include_paths"] = [p for p in j.get("include_paths", []) if os.path.exists(p)]
j["include_paths"] += [p for p in priv if p not in j["include_paths"]]
def reroot(p):
    i = p.rfind("/qml/")
    return p if i < 0 else os.path.join(qml, p[i + 5:])
if "qmltypes" in j:
    j["qmltypes"] = [reroot(p) for p in j["qmltypes"]]
# a layout marker from another distribution filters every header out; xiboca then uses the
# -I that holds QtCore, which is a fact about this Qt
j.pop("qt_marker", None)
json.dump(j, open(out, "w"), indent=1)
EOF

echo "dside-binding: xiboca"
(cd "$DSIDE/xiboca" && dub build --yes --quiet --compiler=ldc2)
rm -rf "$GEN"
(cd "$DSIDE" && ./xiboca/xiboca "$BDIR/spec.derived.json" --out-dir "$GEN" >/dev/null)

echo "dside-binding: libbinding_ldc2.a"
rm -rf "$BDIR/od_ldc2" && mkdir -p "$BDIR/od_ldc2"
(cd "$GEN" && ldc2 -c -oq -od="$BDIR/od_ldc2" -I. $(find . -name '*.d'))
rm -f "$BDIR/libbinding_ldc2.a"
ar rcs "$BDIR/libbinding_ldc2.a" "$BDIR"/od_ldc2/*.o

echo "dside-binding: libshims.a"
rm -rf "$BDIR/ocpp" && mkdir -p "$BDIR/ocpp"
echo yes > "$BDIR/qml-enabled"
for c in "$GEN"/*.cpp; do
    b=$(basename "$c" .cpp)
    case "$b" in qtdmoc|qtdmoc_qml) EX=-DQTD_ENABLE_QML ;; *) EX= ;; esac
    # shellcheck disable=SC2086
    ${CXX:-c++} $CFLAGS $PRIV -std=c++17 -fPIC -O2 -ffunction-sections -fdata-sections $EX \
        -c "$c" -o "$BDIR/ocpp/$b.o"
done
rm -f "$BDIR/libshims.a"
ar rcs "$BDIR/libshims.a" "$BDIR"/ocpp/*.o
echo "dside-binding: $BDIR"
