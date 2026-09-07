project(
  'photo-wagon',
  'cpp',
  version: '0.2.0',
  default_options: [
    'cpp_std=c++17',
    'buildtype=release'
  ]
)

qt = import('qt6')

qt_deps = [
  dependency('qt6', modules: ['Core', 'Gui', 'Qml', 'Quick']),
  dependency('qt6', modules: ['Concurrent']),
  dependency('qt6', modules: ['Network']),
  dependency('qt6', modules: ['WebSockets']),
]

qt_generated = qt.preprocess(
  moc_headers: ['ui/cpp/clipboard_helper.h', 'ui/cpp/daemon_bridge.h'],
  qresources: ['ui/qml/resources.qrc']
)

photo_wagon = executable(
  'photo-wagon',
  [
    'ui/cpp/main.cpp',
    'ui/cpp/clipboard_helper.cpp',
    'ui/cpp/daemon_bridge.cpp',
    'ui/cpp/logging.cpp',
    qt_generated,
  ],
  dependencies: qt_deps,
  install: true
)

# Build the D daemon via dub, then copy the binary into the meson build dir.
# First compile the OpenCV C++ shim that the D daemon links against.
dub_prog = find_program('dub', required: true)
cp_prog = find_program('cp')
gpp_prog = find_program('g++')
ar_prog = find_program('ar')

dub_src = meson.project_source_root() / 'photowagond'
csrc_dir = dub_src / 'csrc'

face_shim = custom_target(
  'face_opencv',
  output: 'libface_opencv.a',
  command: [
    'sh', '-c',
    gpp_prog.full_path() + ' -std=c++17 -O2 -c '
    + csrc_dir / 'face_opencv.cpp'
    + ' -o ' + csrc_dir / 'face_opencv.o'
    + ' `pkg-config --cflags opencv4`'
    + ' && ' + ar_prog.full_path() + ' rcs '
    + csrc_dir / 'libface_opencv.a '
    + csrc_dir / 'face_opencv.o',
  ],
  build_by_default: true,
  console: true,
)

photowagond = custom_target(
  'photowagond',
  output: 'photowagond',
  depends: [face_shim],
  command: [
    'sh', '-c',
    dub_prog.full_path() + ' build --root ' + dub_src + ' --build=release'
    + ' && ' + cp_prog.full_path() + ' ' + dub_src / 'photowagond' + ' @OUTPUT@',
  ],
  build_by_default: true,
  console: true,
  install: true,
  install_dir: get_option('bindir'),
)

summary({
  'Qt modules': 'Core, Gui, Qml, Quick, Concurrent, Network, WebSockets',
  'D daemon': 'photowagond/ (auto-built via dub)',
  'Architecture': 'Qt ⟷ REST + WebSocket events ⟷ D daemon',
}, section: 'Photo Wagon')
