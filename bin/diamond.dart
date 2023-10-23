// TODO: Use logging package
// TODO: Add cursor hotspot

import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:waybright/waybright.dart';

// Close socket by holding Alt while clicking Escape twice
// Switch windows with Alt+Tab
// Launch Weston Terminal with Alt+T

class Vector {
  num x;
  num y;
  Vector(this.x, this.y);
}

class NoMonitorFoundException implements Exception {
  @override
  String toString() => "No monitor found!";
}

class DiamondWindow {
  final _animations = <Animation>[];
  var _newAlpha = 0.0;
  var _newScale = 1.0;
  var _isMaximizingWindow = false;
  var _isUnmaximizingWindow = false;
  var _isFullscreeningWindow = false;
  var _isUnfullscreeningWindow = false;
  var _wasMaximizedBeforeFullscreened = false;

  final Window window;
  DiamondWindow? parent;
  final popups = Queue<DiamondWindow>();
  var alpha = 0.0;
  var scale = 1.0;
  var canReceiveInput = true;
  var isGrabbed = false;
  var isAppearing = false;
  var isMoving = false;
  var isResizing = false;

  num textureX = 0;
  num textureY = 0;

  num get x => textureX + window.offsetX;
  num get y => textureY + window.offsetY;
  set x(num x) => textureX = x - window.offsetX;
  set y(num y) => textureY = y - window.offsetY;

  int get width => window.width;
  int get height => window.height;
  num get textureWidth => window.textureWidth;
  num get textureHeight => window.textureHeight;

  final freeFloatingPosition = Vector(0.0, 0.0);
  final freeFloatingSize = Vector(0.0, 0.0);

  // grabbed when being moved or resized
  final positionAtStartOfGrab = Vector(0.0, 0.0);
  final sizeAtStartOfGrab = Vector(0.0, 0.0);

  var edgeBeingResized = WindowEdge.none;

  String get appId => window.applicationId ?? "";
  String get title => window.title ?? "";
  bool get isPopup => window.isPopup;
  bool get isMaximized => window.isMaximized;
  bool get isFullscreen => window.isFullscreen;
  bool get isFreeFloating => !isMaximized && !isFullscreen;

  DiamondWindow(this.window) {
    _setHandlers();
  }

  void _setHandlers() {
    window.onDestroying = (event) {
      if (this == hoveredWindow) {
        cursor.image = null;
      }

      windows.remove(this);
      if (window.isPopup) {
        parent?.popups.remove(this);
      }

      print("${appId.isEmpty ? "An application" : "Application `$appId`"}"
          "'s 🪟 ${isPopup ? " popup" : ""} window has been removed!");
    };

    window.onTextureSet = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " has ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          "'s texture set!");

      if (isPopup) {
        x = window.popupX + parent!.x;
        y = window.popupY + parent!.y;
        return;
      }

      assignRandomPosition();
      focusWindow(this);
      moveWindowToFront(this);
      appear();
    };

    window.onTextureUnsetting = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          "' texture unset!");

      if (!isPopup && this == focusedWindow) {
        unfocusWindow();

        var hasFoundThisWindow = false;
        for (var otherWindow in windows) {
          if (hasFoundThisWindow) {
            focusWindow(otherWindow);
            break;
          } else if (otherWindow == this) {
            hasFoundThisWindow = true;
          }
        }
      }
    };

    window.onMoveRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " moved!");

      if (!isFullscreen) {
        grab();
      }

      focusWindow(this);
      moveWindowToFront(this);
    };

    window.onResizeRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " resized!");
      print("- Edge: ${event.edge}");

      if (isFreeFloating) {
        grab();
        startResize(event.edge);
      }
    };

    window.onResize = (event) {
      if (!isResizing) return;

      var deltaX = width - sizeAtStartOfGrab.x;
      var deltaY = height - sizeAtStartOfGrab.y;

      switch (edgeBeingResized) {
        case WindowEdge.left:
        case WindowEdge.topLeft:
        case WindowEdge.bottomLeft:
          x = positionAtStartOfGrab.x - deltaX;
          break;
        default:
          break;
      }

      switch (edgeBeingResized) {
        case WindowEdge.top:
        case WindowEdge.topLeft:
        case WindowEdge.topRight:
          y = positionAtStartOfGrab.y - deltaY;
          break;
        default:
          break;
      }
    };

    window.onMaximizeRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " maximized!");

      maximize();
    };

    window.onMaximize = (event) {
      if (!_isMaximizingWindow) return;

      x = 0;
      y = 0;

      _isMaximizingWindow = false;
      print("Maximized 🪟 window!");
    };

    window.onUnmaximizeRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " unmaximized!");

      unmaximize();
    };

    window.onUnmaximize = (event) {
      if (!_isUnmaximizingWindow) return;
      var monitor = currentMonitor;
      if (monitor == null) throw NoMonitorFoundException();

      if (isGrabbed) {
        positionAtStartOfGrab.x = (cursorPositionAtGrab.x - width / 2)
            .clamp(0, monitor.mode.width - width);

        positionAtStartOfGrab.y = -window.offsetY;

        x = positionAtStartOfGrab.x;
        y = positionAtStartOfGrab.y;
      } else {
        x = freeFloatingPosition.x;
        y = freeFloatingPosition.y;
      }

      _isUnmaximizingWindow = false;
      print("Unmaximized 🪟  window!");
    };

    window.onMinimizeRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " minimized!");
    };

    window.onFullscreenRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " fullscreened!");

      fullscreen();
    };

    window.onFullscreen = (event) {
      if (!_isFullscreeningWindow) return;

      x = 0;
      y = 0;

      _isFullscreeningWindow = false;
      print("Fullscreened 🪟 window!");
    };

    window.onUnfullscreenRequest = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟  window" : "the 🪟  window '$title'"}"
          " unfullscreened!");

      unfullscreen();
    };

    window.onUnfullscreen = (event) {
      if (!_isUnfullscreeningWindow) return;

      if (isFreeFloating) {
        x = freeFloatingPosition.x;
        y = freeFloatingPosition.y;
      } else {
        x = 0;
        y = 0;
      }

      _isUnfullscreeningWindow = false;
      print("Unfullscreened 🪟  window!");
    };

    window.onPopupCreate = (event) {
      print("A 🪟  popup window has been added!");

      var popup = DiamondWindow(event.window);
      popup.parent = this;
      popups.add(popup);
    };

    window.onParentChange = (event) {
      print("The 🪟  window's parent has changed!");
    };
  }

  void _updateAnimations() {
    for (var animation in _animations) {
      animation.update();
    }

    _animations.removeWhere((animation) => animation.isDone);
  }

  void grab() {
    cursorPositionAtGrab.x = cursor.position.x;
    cursorPositionAtGrab.y = cursor.position.y;
    positionAtStartOfGrab.x = x;
    positionAtStartOfGrab.y = y;
    sizeAtStartOfGrab.x = width;
    sizeAtStartOfGrab.y = height;
    canReceiveInput = false;
    isGrabbed = true;
  }

  void release() {
    canReceiveInput = true;
    isGrabbed = false;
  }

  void startMove() {
    if (!isGrabbed) grab();

    isMoving = true;
  }

  void stopMove() {
    if (isGrabbed) release();

    isMoving = false;
  }

  void startResize(WindowEdge edge) {
    if (!isGrabbed) grab();

    isResizing = true;
    edgeBeingResized = edge;
    window.notifyResizing(true);
  }

  void stopResize() {
    if (isGrabbed) release();

    isResizing = false;
    window.notifyResizing(false);
  }

  void assignRandomPosition() {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var random = Random();
    x = random.nextInt(monitor.mode.width - width);
    y = random.nextInt(monitor.mode.height - height);
  }

  void maximize() {
    if (_isMaximizingWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (isFullscreen) {
      window.unfullscreen();
      print("Unfullscreening 🪟  window before maximizing...");
    } else {
      freeFloatingPosition.x = x;
      freeFloatingPosition.y = y;
      freeFloatingSize.x = width;
      freeFloatingSize.y = height;
    }
    window.maximize(width: monitor.mode.width, height: monitor.mode.height);
    _isMaximizingWindow = true;
  }

  void unmaximize() {
    if (_isUnmaximizingWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = freeFloatingSize.x.toInt();
    var height = freeFloatingSize.y.toInt();
    window.unmaximize(width: width, height: height);
    _isUnmaximizingWindow = true;
  }

  void fullscreen() {
    if (_isFullscreeningWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (isMaximized) {
      window.unmaximize();
      _wasMaximizedBeforeFullscreened = true;
      print("Unmaximizing 🪟  window before fullscreening...");
    } else {
      freeFloatingPosition.x = x;
      freeFloatingPosition.y = y;
      freeFloatingSize.x = width;
      freeFloatingSize.y = height;
      _wasMaximizedBeforeFullscreened = false;
    }
    window.fullscreen(width: monitor.mode.width, height: monitor.mode.height);
    _isFullscreeningWindow = true;
  }

  void unfullscreen() {
    if (_isUnfullscreeningWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = freeFloatingSize.x.toInt();
    var height = freeFloatingSize.y.toInt();
    window.unfullscreen(width: width, height: height);
    _isUnfullscreeningWindow = true;

    if (_wasMaximizedBeforeFullscreened) {
      window.maximize(width: monitor.mode.width, height: monitor.mode.height);
    }
  }

  void update() {
    _updateAnimations();
  }

  void animateTo({required Duration duration, double? alpha, double? scale}) {
    if (_newAlpha == alpha && _newScale == scale) return;

    var oldAlpha = this.alpha;
    var oldScale = this.scale;

    _newAlpha = alpha ?? oldAlpha;
    _newScale = scale ?? oldScale;

    _animations.add(Animation(
      duration: duration,
      easing: EasingFunctions.easeOutCubic,
      onUpdate: (t) {
        if (alpha != null) this.alpha = oldAlpha + (_newAlpha - oldAlpha) * t;
        if (scale != null) this.scale = oldScale + (_newScale - oldScale) * t;
      },
    ));
  }

  void appear() {
    // canReceiveInput = false;
    alpha = 0.0;
    scale = 0.9;
    _newAlpha = 1.0;
    _newScale = 1.0;
    isAppearing = true;

    _animations.add(Animation(
      duration: Duration(milliseconds: 300),
      easing: EasingFunctions.easeOutCubic,
      onUpdate: (t) {
        alpha = t;
        scale = 0.9 + 0.1 * t;
      },
      onDone: () {
        // canReceiveInput = true;
        isAppearing = false;
      },
    ));
  }
}

class DiamondCursor {
  Image? image;
  Vector hotspot = Vector(0.0, 0.0);
  Vector position = Vector(0.0, 0.0);

  DiamondCursor();
}

const backgroundColors = [
  0x333355ff,
  0xffaaaaff,
];

const terminalProgram = "weston-terminal";
const wallpaperImagePath = "../assets/cubes.png";

Waybright? diamond;

Image? wallpaperImage;

var monitors = <Monitor>[];
var windows = Queue<DiamondWindow>();
var inputDevices = <InputDevice>[];

Monitor? currentMonitor;

var isFocusedWindowFocusedFromPointer = false;
var isBackgroundFocusedFromPointer = false;

var cursor = DiamondCursor();
var cursorPositionAtGrab = Vector(0.0, 0.0);

var windowSwitchIndex = 0;
var isSwitchingWindows = false;
var hasSwitchedWindows = false;
var tempWindowList = <DiamondWindow>[];

var readyToQuit = false;

var isLeftAltKeyPressed = false;
var isRightAltKeyPressed = false;
bool get isAltKeyPressed => isLeftAltKeyPressed || isRightAltKeyPressed;
var isLeftShiftKeyPressed = false;
var isRightShiftKeyPressed = false;
bool get isShiftKeyPressed => isLeftShiftKeyPressed || isRightShiftKeyPressed;

bool get canSubmitPointerMoveEvents =>
    !isSwitchingWindows && !isBackgroundFocusedFromPointer;

bool get canSubmitPointerButtonEvents => !isSwitchingWindows;

bool get canSubmitPointerScrollEvents => !isSwitchingWindows;

bool get doesWindowWantBlankCursor =>
    !isSwitchingWindows && hoveredWindow != null && cursor.image == null;

DiamondWindow? focusedWindow;
DiamondWindow? get hoveredWindow => getHoveredWindowFromList(windows);

bool canImageBeDrawn(Image? image) => image?.isLoaded ?? false;

double getDistanceBetweenPoints(Vector point1, Vector point2) {
  var x = point1.x - point2.x;
  var y = point1.y - point2.y;
  return sqrt(x * x + y * y);
}

void clearAllInputDeviceFocus() {
  for (var inputDevice in inputDevices) {
    if (inputDevice is PointerDevice) {
      inputDevice.clearFocus();
    } else if (inputDevice is KeyboardDevice) {
      inputDevice.clearFocus();
    }
  }
}

void moveWindowToFront(DiamondWindow window) {
  windows.remove(window);
  windows.addFirst(window);
}

void focusWindow(DiamondWindow window) {
  if (focusedWindow == window) return;
  print("Redirecting 🪟  window 🔎 focus...");

  if (focusedWindow != null) {
    focusedWindow?.window.deactivate();
    clearAllInputDeviceFocus();
  }

  window.window.activate();
  focusedWindow = window;
}

void unfocusWindow() {
  if (focusedWindow == null) return;
  print("🔎 Unfocusing 🪟  window...");

  focusedWindow?.window.deactivate();
  focusedWindow = null;
}

bool isCursorOnWindow(DiamondWindow window) {
  return window.x <= cursor.position.x &&
      window.y <= cursor.position.y &&
      window.x + window.width >= cursor.position.x &&
      window.y + window.height >= cursor.position.y;
}

DiamondWindow? getHoveredWindowFromList(Queue<DiamondWindow> windows) {
  for (var window in windows) {
    var popups = window.popups;
    var hoveredPopup = getHoveredWindowFromList(popups);
    if (hoveredPopup != null) return hoveredPopup;

    if (isCursorOnWindow(window)) return window;
  }

  return null;
}

void drawCursor(Renderer renderer) {
  if (doesWindowWantBlankCursor) {
    return;
  } else if (canImageBeDrawn(cursor.image)) {
    renderer.drawImage(
      cursor.image!,
      cursor.position.x - cursor.hotspot.x,
      cursor.position.y - cursor.hotspot.y,
    );
    return;
  }

  var borderColor = hoveredWindow == null ? 0xffffffff : 0x000000ff;

  int color;
  if (focusedWindow != null && hoveredWindow == focusedWindow) {
    color = 0x88ff88ff;
  } else if (hoveredWindow != null) {
    color = 0xffaa88ff;
  } else {
    color = 0x000000ff;
  }

  renderer.fillColor = borderColor;
  renderer.fillRect(cursor.position.x - 2, cursor.position.y - 2, 5, 5);
  renderer.fillColor = color;
  renderer.fillRect(cursor.position.x - 1, cursor.position.y - 1, 3, 3);
}

void drawPopups(Renderer renderer, DiamondWindow window) {
  var popups = window.popups;
  for (var popup in popups) {
    renderer.drawWindow(popup.window, popup.textureX, popup.textureY);
    drawPopups(renderer, popup);
  }
}

void drawWindows(Renderer renderer) {
  windows.toList().reversed.forEach((window) => drawWindow(renderer, window));
}

void drawWindow(Renderer renderer, DiamondWindow window) {
  window.update();

  if (!window.isAppearing) {
    var alpha = 1.0;
    var scale = 1.0;

    if (isSwitchingWindows) {
      if (window == focusedWindow) {
        alpha = 1.0;
        scale = window.isFreeFloating ? 1.05 : 0.98;
      } else {
        alpha = window.isFullscreen ? 1.0 : 0.7;
        scale = 0.95;
      }
    }

    window.animateTo(
      duration: Duration(milliseconds: 200),
      alpha: alpha,
      scale: scale,
    );
  }

  var width = (window.textureWidth * window.scale).toInt();
  var height = (window.textureHeight * window.scale).toInt();
  var x = window.textureX - (width - window.textureWidth) ~/ 2;
  var y = window.textureY - (height - window.textureHeight) ~/ 2;
  var alpha = window.alpha;

  renderer.drawWindow(window.window, x, y,
      width: width, height: height, alpha: alpha);
  drawPopups(renderer, window);
}

void drawWallpaper(Renderer renderer) {
  var monitor = currentMonitor;
  if (monitor == null) throw NoMonitorFoundException();

  if (canImageBeDrawn(wallpaperImage)) {
    var monitorWidth = monitor.mode.width;
    var monitorHeight = monitor.mode.height;
    var imageWidth = wallpaperImage!.width;
    var imageHeight = wallpaperImage!.height;

    var monitorSizeRatio = monitorWidth / monitorHeight;
    var imageSizeRatio = imageWidth / imageHeight;

    double scale;
    if (monitorSizeRatio > imageSizeRatio) {
      scale = monitorWidth / imageWidth;
    } else {
      scale = monitorHeight / imageHeight;
    }

    // Cover screen while maintaining aspect ratio.
    var x = (monitorWidth - imageWidth * scale) ~/ 2;
    var y = (monitorHeight - imageHeight * scale) ~/ 2;
    var width = (imageWidth * scale).toInt();
    var height = (imageHeight * scale).toInt();

    renderer.drawImage(wallpaperImage!, x, y, width: width, height: height);
  }
}

void handleCurrentMonitorFrame() {
  var monitor = currentMonitor;
  if (monitor == null) throw NoMonitorFoundException();

  var renderer = monitor.renderer;

  renderer.begin();
  renderer.clear();

  drawWallpaper(renderer);

  renderer.fillColor = 0x6666ffff;
  renderer.fillRect(50, 50, 100, 100);

  drawWindows(renderer);
  drawCursor(renderer);

  renderer.end();
  renderer.render();
}

void initializeMonitor(Monitor monitor) {
  var modes = monitor.modes;
  var preferredMode = monitor.preferredMode;

  print("- Name: '${monitor.name}'");
  print("- Number of modes: ${modes.length}");
  if (modes.isNotEmpty) {
    print("- Preferred mode: "
        "${preferredMode == null ? "none" : "$preferredMode"}");
  }

  if (preferredMode != null) monitor.mode = preferredMode;
  monitor.enable();

  monitor.onRemoving = (event) {
    monitors.remove(monitor);
    print("A 📺 monitor has been removed!");
    print("- Name: '${monitor.name}'");

    if (monitor == currentMonitor) {
      currentMonitor = monitors.isEmpty ? null : monitors.first;
    }
  };

  monitor.renderer.clearColor =
      backgroundColors[(monitors.length - 1) % backgroundColors.length];

  if (monitors.length == 1) {
    currentMonitor = monitor;

    cursor.position.x = monitor.mode.width / 2;
    cursor.position.y = monitor.mode.height / 2;

    monitor.onFrame = (event) => handleCurrentMonitorFrame();
  } else {
    var renderer = monitor.renderer;

    monitor.onFrame = (event) {
      renderer.begin();
      renderer.clear();

      renderer.fillColor = 0xffdd66ff;
      renderer.fillRect(50, 50, 100, 100);

      renderer.end();
      renderer.render();
    };
  }
}

void handleNewMonitor(MonitorAddEvent event) {
  Monitor monitor = event.monitor;
  monitors.add(monitor);

  print("A 📺 monitor has been added!");

  initializeMonitor(monitor);
}

void handleWindowCreate(WindowCreateEvent event) {
  var window = DiamondWindow(event.window);
  windows.addFirst(window);

  final appId = window.appId;
  final title = window.title;

  print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
      "'s 🪟 ${window.isPopup ? " popup" : ""} window has been added!");

  if (title.isNotEmpty) print("- Title: '$title'");
}

void handleWindowHover(PointerMoveEvent event) {
  if (!canSubmitPointerMoveEvents) return;
  var pointer = event.pointer;

  var focusedWindow_ = focusedWindow;
  if (isFocusedWindowFocusedFromPointer &&
      focusedWindow_ != null &&
      focusedWindow_.canReceiveInput) {
    focusedWindow_.window.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.position.x - focusedWindow_.textureX).toDouble(),
      (cursor.position.y - focusedWindow_.textureY).toDouble(),
    ));
    return;
  }

  var hoveredWindow_ = hoveredWindow;
  if (hoveredWindow_ != null && hoveredWindow_.canReceiveInput) {
    hoveredWindow_.window.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.position.x - hoveredWindow_.textureX).toDouble(),
      (cursor.position.y - hoveredWindow_.textureY).toDouble(),
    ));
    return;
  }

  cursor.image = null;
  for (var inputDevice in inputDevices) {
    if (inputDevice is PointerDevice) {
      inputDevice.clearFocus();
    }
  }
}

void handleWindowMove() {
  var window = focusedWindow;
  if (window == null) return;

  window.x = window.positionAtStartOfGrab.x +
      cursor.position.x -
      cursorPositionAtGrab.x;
  window.y = window.positionAtStartOfGrab.y +
      cursor.position.y -
      cursorPositionAtGrab.y;
}

void handleWindowResize() {
  var window = focusedWindow;
  if (window == null) return;

  var deltaX = cursor.position.x - cursorPositionAtGrab.x;
  var deltaY = cursor.position.y - cursorPositionAtGrab.y;

  var width = window.sizeAtStartOfGrab.x;
  var height = window.sizeAtStartOfGrab.y;

  switch (window.edgeBeingResized) {
    case WindowEdge.left:
    case WindowEdge.topLeft:
    case WindowEdge.bottomLeft:
      width -= deltaX;
      break;
    case WindowEdge.right:
    case WindowEdge.topRight:
    case WindowEdge.bottomRight:
      width += deltaX;
      break;
    default:
      break;
  }

  switch (window.edgeBeingResized) {
    case WindowEdge.top:
    case WindowEdge.topLeft:
    case WindowEdge.topRight:
      height -= deltaY;
      break;
    case WindowEdge.bottom:
    case WindowEdge.bottomLeft:
    case WindowEdge.bottomRight:
      height += deltaY;
      break;
    default:
      break;
  }

  window.window.requestSize(width: width.toInt(), height: height.toInt());
}

void handlePointerMovement(PointerMoveEvent event) {
  var window = focusedWindow;
  if (window != null) {
    if (window.isGrabbed && !window.isMoving && !window.isResizing) {
      var distance =
          getDistanceBetweenPoints(cursorPositionAtGrab, cursor.position);
      if (distance >= 15) {
        if (window.isMaximized) {
          window.unmaximize();
        }
        window.startMove();
      }
    }

    if (window.isMoving) {
      handleWindowMove();
    } else if (window.isResizing) {
      handleWindowResize();
    } else {
      handleWindowHover(event);
    }
  }
}

void focusOnBackground() {
  if (focusedWindow != null) {
    unfocusWindow();
    print("Removed 🪟  window 🔎 focus.");
  }
  isBackgroundFocusedFromPointer = true;
}

void handleNewPointer(PointerDevice pointer) {
  pointer.onMove = (event) {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var speed = 0.5; // my preference
    cursor.position.x =
        (cursor.position.x + event.deltaX * speed).clamp(0, monitor.mode.width);
    cursor.position.y = (cursor.position.y + event.deltaY * speed)
        .clamp(0, monitor.mode.height);

    handlePointerMovement(event);
  };
  pointer.onTeleport = (event) {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();
    if (event.monitor != monitor) return;

    cursor.position.x = event.x.clamp(0, monitor.mode.width);
    cursor.position.y = event.y.clamp(0, monitor.mode.height);

    handlePointerMovement(event);
  };
  pointer.onButton = (event) {
    var hoveredWindow_ = hoveredWindow;

    if (hoveredWindow_ == null) {
      if (event.isPressed) {
        focusOnBackground();
      } else {
        if (canSubmitPointerButtonEvents && isFocusedWindowFocusedFromPointer) {
          var window = focusedWindow;
          if (window != null && window.canReceiveInput) {
            window.window.submitPointerButtonUpdate(PointerUpdate(
              pointer,
              event,
              (cursor.position.x - window.textureX).toDouble(),
              (cursor.position.y - window.textureY).toDouble(),
            ));
          }
        }
      }
    } else if (hoveredWindow_.canReceiveInput) {
      if (event.isPressed) {
        if (hoveredWindow_.isPopup) {
          hoveredWindow_.window.activate();
          focusedWindow = hoveredWindow_;
        } else if (focusedWindow != hoveredWindow_) {
          focusWindow(hoveredWindow_);
          moveWindowToFront(hoveredWindow_);
        }

        if (canSubmitPointerButtonEvents) {
          hoveredWindow_.window.submitPointerButtonUpdate(PointerUpdate(
            pointer,
            event,
            (cursor.position.x - hoveredWindow_.textureX).toDouble(),
            (cursor.position.y - hoveredWindow_.textureY).toDouble(),
          ));
          isFocusedWindowFocusedFromPointer = true;
        }
      } else if (canSubmitPointerButtonEvents) {
        var window = focusedWindow;
        if (window != null && window.canReceiveInput) {
          window.window.submitPointerButtonUpdate(PointerUpdate(
            pointer,
            event,
            (cursor.position.x - window.textureX).toDouble(),
            (cursor.position.y - window.textureY).toDouble(),
          ));
        }
      }
    }

    if (!event.isPressed) {
      var window = focusedWindow;
      if (window != null) {
        if (window.isGrabbed) {
          window.release();
        }

        if (window.isMoving) {
          if (window.y < 0 && window.isFreeFloating) {
            window.maximize();
          }
          window.stopMove();
        }

        if (window.isResizing) {
          window.stopResize();
        }
      }

      isFocusedWindowFocusedFromPointer = false;
      isBackgroundFocusedFromPointer = false;
    }
  };
  pointer.onAxis = (event) {
    if (!canSubmitPointerScrollEvents) return;

    var window = hoveredWindow;
    if (window != null && window.canReceiveInput) {
      window.window.submitPointerAxisUpdate(PointerUpdate(
        pointer,
        event,
        (cursor.position.x - window.textureX).toDouble(),
        (cursor.position.y - window.textureY).toDouble(),
      ));
    }
  };
  pointer.onRemove = (event) {
    inputDevices.remove(pointer);
    print("A 🖱️  pointer has been removed!");
    print("- Name: '${pointer.name}'");
  };
}

void handleWindowSwitching(KeyboardDevice keyboard) {
  if (!isSwitchingWindows) {
    isSwitchingWindows = true;
    cursor.image = null;
    windowSwitchIndex = 0;
    tempWindowList = windows.toList();
  }

  if (focusedWindow != null) {
    var direction = isShiftKeyPressed ? -1 : 1;
    windowSwitchIndex = (windowSwitchIndex + direction) % tempWindowList.length;
  }

  if (windows.isNotEmpty) {
    try {
      var window = tempWindowList.elementAt(windowSwitchIndex);
      focusWindow(window);
      moveWindowToFront(window);
    } catch (e) {
      print(e);
    }
  }
}

void launchTerminal() {
  Isolate.run(() {
    print("Launching 🖥️  Terminal '$terminalProgram' ...");
    try {
      Process.runSync(terminalProgram, []);
    } catch (e) {
      stderr.writeln("Failed to launch 🖥️ '$terminalProgram': $e");
    }
  });
}

void updateKeys(KeyboardKeyEvent event) {
  switch (event.key) {
    case InputDeviceButton.altLeft:
      isLeftAltKeyPressed = event.isPressed;
      break;
    case InputDeviceButton.altRight:
      isRightAltKeyPressed = event.isPressed;
      break;
    case InputDeviceButton.shiftLeft:
      isLeftShiftKeyPressed = event.isPressed;
      break;
    case InputDeviceButton.shiftRight:
      isRightShiftKeyPressed = event.isPressed;
      break;
    default:
  }
}

void quit() {
  diamond?.closeSocket();
  print("~~~ Socket closed ~~~");
}

void handleKeyBindings(KeyboardKeyEvent event) {
  switch (event.key) {
    case InputDeviceButton.escape:
      if (readyToQuit) {
        quit();
      } else if (isAltKeyPressed) {
        readyToQuit = true;
      }
      break;
    case InputDeviceButton.tab:
      if (isAltKeyPressed) handleWindowSwitching(event.keyboard);
      break;
    case InputDeviceButton.keyT:
      if (isAltKeyPressed) launchTerminal();
      break;
    default:
  }
}

void handleNewKeyboard(KeyboardDevice keyboard) {
  keyboard.onKey = (event) {
    updateKeys(event);

    if (event.isPressed) {
      handleKeyBindings(event);
    }

    if (!isAltKeyPressed) {
      isSwitchingWindows = false;
      readyToQuit = false;
    }

    if (!isSwitchingWindows) {
      var window = focusedWindow;
      if (window != null && window.canReceiveInput) {
        window.window.submitKeyboardKeyUpdate(KeyboardUpdate(
          keyboard,
          event,
        ));
      }
    }
  };
  keyboard.onModifiers = (event) {
    var window = focusedWindow;
    if (window != null && window.canReceiveInput) {
      window.window.submitKeyboardModifiersUpdate(KeyboardUpdate(
        keyboard,
        event,
      ));
    }
  };
  keyboard.onRemove = (event) {
    inputDevices.remove(keyboard);
    print("A ⌨️  keyboard has been removed!");
    print("- Name: '${keyboard.name}'");
  };
}

void handleNewInput(NewInputEvent event) {
  var pointer = event.pointer;
  var keyboard = event.keyboard;

  if (pointer != null) {
    inputDevices.add(pointer);
    print("A 🖱️  pointer has been added!");
    print("- Name: '${pointer.name}'");

    handleNewPointer(pointer);
  } else if (keyboard != null) {
    inputDevices.add(keyboard);
    print("A ⌨️  keyboard has been added!");
    print("- Name: '${keyboard.name}'");

    handleNewKeyboard(keyboard);
  }
}

void handleCursorImage(CursorImageEvent event) {
  cursor.image = event.image;
  cursor.hotspot.x = event.hotspotX;
  cursor.hotspot.y = event.hotspotY;
}

Map<String, String> getOptions(List<String> arguments) {
  var options = <String, String>{};

  for (var i = 0; i < arguments.length; i++) {
    var argument = arguments[i];
    if (argument.startsWith("-")) {
      var option = argument.substring(1);
      try {
        var value = arguments[i + 1];
        options[option] = value;
      } catch (e) {
        options[option] = "";
      }
    }
  }

  return options;
}

void main(List<String> arguments) async {
  diamond = Waybright()
    ..onMonitorAdd = handleNewMonitor
    ..onWindowCreate = handleWindowCreate
    ..onNewInput = handleNewInput
    ..onCursorImage = handleCursorImage;

  var options = getOptions(arguments);
  var wallpaperPath = options["i"] ?? wallpaperImagePath;
  var program = options["p"];

  try {
    print("Loading 🖼️  wallpaper '$wallpaperPath'...");
    wallpaperImage = await diamond?.loadImage(wallpaperPath);
    if (wallpaperImage?.isLoaded ?? false) {
      print("🖼️  Wallpaper loaded!");
    } else {
      wallpaperImage?.onLoad = (event) => print("🖼️  Wallpaper loaded!");
    }
  } catch (e) {
    stderr.writeln("Failed to load 🖼️  wallpaper '$wallpaperPath': $e");
  }

  try {
    var socketName = diamond?.openSocket();
    print("~~~ Socket opened on '$socketName' ~~~");

    if (program != null) {
      print("Running 🖥️  program '$program' ...");
      try {
        Isolate.run(() => Process.runSync(program, []));
      } catch (e) {
        stderr.writeln("Failed to run 🖥️  program '$program': $e");
      }
    }
  } catch (e) {
    print(e);
  }
}
