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
  var _isMaximizingFocusedWindow = false;
  var _isUnmaximizingFocusedWindow = false;
  var _isFullscreeningFocusedWindow = false;
  var _isUnfullscreeningFocusedWindow = false;
  var _wasMaximizedBeforeFullscreened = false;

  final Window window;
  DiamondWindow? parent;
  final popups = Queue<DiamondWindow>();
  final unmaximizedPosition = Vector(0.0, 0.0);
  final unmaximizedSize = Vector(0.0, 0.0);
  var alpha = 0.0;
  var scale = 1.0;
  var canReceiveInput = true;
  var isAppearing = false;

  String get appId => window.appId;
  String get title => window.title;
  bool get isPopup => window.isPopup;
  bool get isMaximized => window.isMaximized;
  bool get isFullscreen => window.isFullscreen;
  bool get isFreeFloating => !isMaximized && !isFullscreen;

  DiamondWindow(this.window) {
    setHandlers();
  }

  void setHandlers() {
    window.onRemove = (event) {
      if (this == hoveredWindow) {
        cursorImage = null;
      }

      windows.remove(this);
      if (window.isPopup) {
        parent?.popups.remove(this);
      }

      print("${appId.isEmpty ? "An application" : "Application `$appId`"}"
          "'s 🪟${window.isPopup ? " popup" : ""} window has been removed!");
    };

    window.onShow = (event) {
      if (window.isPopup) {
        var parent = window.parent!;
        window.drawingX = window.popupX + parent.contentX;
        window.drawingY = window.popupY + parent.contentY;
        return;
      }

      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " shown!");

      assignRandomPosition();
      focusWindow(this);
      moveWindowToFront(this);
      appear();
    };

    window.onHide = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " hidden!");

      if (this == focusedWindow) {
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

    // The window wants to be moved, which has to be handled manually.
    window.onMove = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " moved!");

      isGrabbingFocusedWindow = true;
      cursorPositionAtGrab.x = cursor.x;
      cursorPositionAtGrab.y = cursor.y;
      windowDrawingPositionAtGrab.x = window.drawingX;
      windowDrawingPositionAtGrab.y = window.drawingY;

      focusWindow(this);
      moveWindowToFront(this);
    };

    // The window wants to be resized, which has to be handled manually.
    window.onResize = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " resized!");
      print("- Edge: ${event.edge}");

      if (isFreeFloating) {
        isResizingFocusedWindow = true;
        cursorPositionAtGrab.x = cursor.x;
        cursorPositionAtGrab.y = cursor.y;
        windowDrawingPositionAtGrab.x = window.drawingX;
        windowDrawingPositionAtGrab.y = window.drawingY;
        windowWidthAtGrab = window.contentWidth;
        windowHeightAtGrab = window.contentHeight;
        edgeOfWindowResize = event.edge;
      }
    };

    // The window wants to be maximize, which has to be handled manually.
    window.onMaximize = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " ${isMaximized ? "un" : ""}maximized!");

      if (isMaximized) {
        unmaximize();
      } else {
        maximize();
      }
    };

    // The window wants to be fullscreened, which has to be handled manually.
    window.onFullscreen = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " ${isFullscreen ? "un" : ""}fullscreened!");

      if (isFullscreen) {
        unfullscreen();
      } else {
        fullscreen();
      }
    };

    window.onNewPopup = (event) {
      print("A 🪟 popup window has been added!");

      var popup = DiamondWindow(event.window);
      popup.parent = this;
      popups.add(popup);
    };
  }

  void assignRandomPosition() {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var random = Random();
    var x = random.nextInt(monitor.mode.width - window.contentWidth);
    var y = random.nextInt(monitor.mode.height - window.contentHeight);

    window.drawingX = x - window.contentX;
    window.drawingY = y - window.contentY;
  }

  void maximize() {
    if (_isMaximizingFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (isFullscreen) {
      window.unfullscreen();
      print("Unfullscreening 🪟 window before maximizing...");
    } else {
      unmaximizedPosition.x = window.drawingX;
      unmaximizedPosition.y = window.drawingY;
      unmaximizedSize.x = window.contentWidth;
      unmaximizedSize.y = window.contentHeight;
    }
    window.maximize(width: monitor.mode.width, height: monitor.mode.height);
    _isMaximizingFocusedWindow = true;
  }

  void unmaximize() {
    if (_isUnmaximizingFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = unmaximizedSize.x.toInt();
    var height = unmaximizedSize.y.toInt();
    window.unmaximize(width: width, height: height);
    _isUnmaximizingFocusedWindow = true;
  }

  void fullscreen() {
    if (_isFullscreeningFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (isMaximized) {
      window.unmaximize();
      _wasMaximizedBeforeFullscreened = true;
      print("Unmaximizing 🪟 window before fullscreening...");
    } else {
      unmaximizedPosition.x = window.drawingX;
      unmaximizedPosition.y = window.drawingY;
      unmaximizedSize.x = window.contentWidth;
      unmaximizedSize.y = window.contentHeight;
      _wasMaximizedBeforeFullscreened = false;
    }
    window.fullscreen(width: monitor.mode.width, height: monitor.mode.height);
    _isFullscreeningFocusedWindow = true;
  }

  void unfullscreen() {
    if (_isUnfullscreeningFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = unmaximizedSize.x.toInt();
    var height = unmaximizedSize.y.toInt();
    window.unfullscreen(width: width, height: height);
    _isUnfullscreeningFocusedWindow = true;

    if (_wasMaximizedBeforeFullscreened) {
      window.maximize(width: monitor.mode.width, height: monitor.mode.height);
    }
  }

  void updatePosition() {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var x = 0;
    var y = 0;

    if (isGrabbingFocusedWindow) {
      windowDrawingPositionAtGrab.x =
          (cursorPositionAtGrab.x - window.contentWidth / 2)
                  .clamp(0, monitor.mode.width - window.contentWidth) -
              window.offsetX;

      windowDrawingPositionAtGrab.y = -window.offsetY;

      x = windowDrawingPositionAtGrab.x.toInt();
      y = windowDrawingPositionAtGrab.y.toInt();
    } else if (isFreeFloating) {
      x = unmaximizedPosition.x.toInt();
      y = unmaximizedPosition.y.toInt();
    }

    window.drawingX = x;
    window.drawingY = y;
  }

  void updateAnimations() {
    for (var animation in _animations) {
      animation.update();
    }

    _animations.removeWhere((animation) => animation.isDone);
  }

  void update() {
    updateAnimations();

    if (_isMaximizingFocusedWindow) {
      if (isMaximized) {
        _isMaximizingFocusedWindow = false;
        updatePosition();
        print("Maximized 🪟 window!");
      }
    } else if (_isUnmaximizingFocusedWindow) {
      if (!isMaximized) {
        _isUnmaximizingFocusedWindow = false;
        updatePosition();
        print("Unmaximized 🪟 window!");
      }
    } else if (_isFullscreeningFocusedWindow) {
      if (isFullscreen) {
        _isFullscreeningFocusedWindow = false;
        updatePosition();
        print("Fullscreened 🪟 window!");
      }
    } else if (_isUnfullscreeningFocusedWindow) {
      if (!isFullscreen) {
        _isUnfullscreeningFocusedWindow = false;
        updatePosition();
        print("Unfullscreened 🪟 window!");
      }
    }
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
    canReceiveInput = false;
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
        canReceiveInput = true;
        isAppearing = false;
      },
    ));
  }
}

const backgroundColors = [
  0x333355ff,
  0xffaaaaff,
];

const terminalProgram = "weston-terminal";
const wallpaperImagePath = "../assets/cubes.png";

Waybright? diamond;

Image? cursorImage;
Image? wallpaperImage;

var monitors = <Monitor>[];
var windows = Queue<DiamondWindow>();
var inputDevices = <InputDevice>[];

Monitor? currentMonitor;

var isFocusedWindowFocusedFromPointer = false;
var isBackgroundFocusedFromPointer = false;
var isGrabbingFocusedWindow = false;
var isMovingFocusedWindow = false;
var isResizingFocusedWindow = false;

var cursor = Vector(0.0, 0.0);
var windowDrawingPositionAtGrab = Vector(0.0, 0.0);
var cursorPositionAtGrab = Vector(0.0, 0.0);

var windowWidthAtGrab = 0;
var windowHeightAtGrab = 0;
var edgeOfWindowResize = WindowEdge.none;

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
    !isSwitchingWindows && hoveredWindow != null && cursorImage == null;

DiamondWindow? focusedWindow;
DiamondWindow? get hoveredWindow => getHoveredWindowFromList(windows);

bool canImageBeDrawn(Image? image) => image?.isReady ?? false;

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
  print("Redirecting 🪟 window 🔎 focus...");

  if (focusedWindow != null) {
    focusedWindow?.window.unfocus();
    clearAllInputDeviceFocus();
  }

  window.window.focus();
  focusedWindow = window;
}

void unfocusWindow() {
  if (focusedWindow == null) return;
  print("🔎 Unfocusing 🪟 window...");

  focusedWindow?.window.unfocus();
  focusedWindow = null;
}

bool isCursorOnWindow(DiamondWindow window) {
  return window.window.contentX <= cursor.x &&
      window.window.contentY <= cursor.y &&
      window.window.contentX + window.window.contentWidth >= cursor.x &&
      window.window.contentY + window.window.contentHeight >= cursor.y;
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
  } else if (canImageBeDrawn(cursorImage)) {
    renderer.drawImage(
      cursorImage!,
      cursor.x + cursorImage!.offsetX,
      cursor.y + cursorImage!.offsetY,
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

  renderer.fillStyle = borderColor;
  renderer.fillRect(cursor.x - 2, cursor.y - 2, 5, 5);
  renderer.fillStyle = color;
  renderer.fillRect(cursor.x - 1, cursor.y - 1, 3, 3);
}

void drawPopups(Renderer renderer, DiamondWindow window) {
  var popups = window.popups;
  for (var popup in popups) {
    renderer.drawWindow(
        popup.window, popup.window.drawingX, popup.window.drawingY);
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

  var width = (window.window.drawingWidth * window.scale).toInt();
  var height = (window.window.drawingHeight * window.scale).toInt();
  var x = window.window.drawingX - (width - window.window.drawingWidth) ~/ 2;
  var y = window.window.drawingY - (height - window.window.drawingHeight) ~/ 2;
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

  drawWallpaper(renderer);

  renderer.fillStyle = 0x6666ffff;
  renderer.fillRect(50, 50, 100, 100);

  drawWindows(renderer);
  drawCursor(renderer);
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

  monitor.onRemove = (event) {
    monitors.remove(monitor);
    print("A 📺 monitor has been removed!");
    print("- Name: '${monitor.name}'");

    if (monitor == currentMonitor) {
      currentMonitor = monitors.isEmpty ? null : monitors.first;
    }
  };

  monitor.renderer.backgroundColor =
      backgroundColors[(monitors.length - 1) % backgroundColors.length];

  if (monitors.length == 1) {
    currentMonitor = monitor;

    cursor.x = monitor.mode.width / 2;
    cursor.y = monitor.mode.height / 2;

    monitor.onFrame = (event) => handleCurrentMonitorFrame();
  } else {
    var renderer = monitor.renderer;

    monitor.onFrame = (event) {
      renderer.fillStyle = 0xffdd66ff;
      renderer.fillRect(50, 50, 100, 100);
    };
  }
}

void handleNewMonitor(NewMonitorEvent event) {
  Monitor monitor = event.monitor;
  monitors.add(monitor);

  print("A 📺 monitor has been added!");

  initializeMonitor(monitor);
}

void handleNewWindow(NewWindowEvent event) {
  var window = DiamondWindow(event.window);

  windows.addFirst(window);

  final appId = window.appId;
  final title = window.title;

  print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
      "'s 🪟${window.isPopup ? " popup" : ""} window has been added!");

  if (title.isNotEmpty) print("- Title: '$title'");
}

void handleWindowHover(PointerMoveEvent event) {
  if (!canSubmitPointerMoveEvents) return;
  var pointer = event.pointer;

  var window = focusedWindow;
  if (isFocusedWindowFocusedFromPointer &&
      window != null &&
      window.canReceiveInput) {
    window.window.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.x - window.window.drawingX).toDouble(),
      (cursor.y - window.window.drawingY).toDouble(),
    ));
    return;
  }

  var hoveredWindow_ = hoveredWindow;
  if (hoveredWindow_ != null && hoveredWindow_.canReceiveInput) {
    hoveredWindow_.window.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.x - hoveredWindow_.window.drawingX).toDouble(),
      (cursor.y - hoveredWindow_.window.drawingY).toDouble(),
    ));
    return;
  }

  cursorImage = null;
  for (var inputDevice in inputDevices) {
    if (inputDevice is PointerDevice) {
      inputDevice.clearFocus();
    }
  }
}

void handleWindowMove() {
  focusedWindow?.window.drawingX =
      windowDrawingPositionAtGrab.x + cursor.x - cursorPositionAtGrab.x;
  focusedWindow?.window.drawingY =
      windowDrawingPositionAtGrab.y + cursor.y - cursorPositionAtGrab.y;
}

void handleWindowResize() {
  var window = focusedWindow;
  if (window == null) return;

  var deltaX = cursor.x - cursorPositionAtGrab.x;
  var deltaY = cursor.y - cursorPositionAtGrab.y;

  num x = windowDrawingPositionAtGrab.x;
  num y = windowDrawingPositionAtGrab.y;
  num width = windowWidthAtGrab;
  num height = windowHeightAtGrab;

  switch (edgeOfWindowResize) {
    case WindowEdge.top:
    case WindowEdge.topLeft:
    case WindowEdge.topRight:
      y += deltaY;
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

  switch (edgeOfWindowResize) {
    case WindowEdge.left:
    case WindowEdge.topLeft:
    case WindowEdge.bottomLeft:
      x += deltaX;
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

  window.window.drawingX = x;
  window.window.drawingY = y;
  window.window.submitNewSize(width: width.toInt(), height: height.toInt());
}

void handlePointerMovement(PointerMoveEvent event) {
  var window = focusedWindow;
  if (window != null && isGrabbingFocusedWindow && window.canReceiveInput) {
    var distance = getDistanceBetweenPoints(cursorPositionAtGrab, cursor);
    if (distance >= 15) {
      if (window.isMaximized) {
        window.unmaximize();
      }
      isMovingFocusedWindow = true;
    }
  }

  if (isMovingFocusedWindow) {
    handleWindowMove();
  } else if (isResizingFocusedWindow) {
    handleWindowResize();
  } else {
    handleWindowHover(event);
  }
}

void focusOnBackground() {
  if (focusedWindow != null) {
    unfocusWindow();
    print("Removed 🪟 window 🔎 focus.");
  }
  isBackgroundFocusedFromPointer = true;
}

void handleNewPointer(PointerDevice pointer) {
  pointer.onMove = (event) {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var speed = 0.5; // my preference
    cursor.x = (cursor.x + event.deltaX * speed).clamp(0, monitor.mode.width);
    cursor.y = (cursor.y + event.deltaY * speed).clamp(0, monitor.mode.height);

    handlePointerMovement(event);
  };
  pointer.onTeleport = (event) {
    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();
    if (event.monitor != monitor) return;

    cursor.x = event.x.clamp(0, monitor.mode.width);
    cursor.y = event.y.clamp(0, monitor.mode.height);

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
              (cursor.x - window.window.drawingX).toDouble(),
              (cursor.y - window.window.drawingY).toDouble(),
            ));
          }
        }
      }
    } else if (hoveredWindow_.canReceiveInput) {
      if (event.isPressed) {
        if (hoveredWindow_.isPopup) {
          hoveredWindow_.window.focus();
          focusedWindow = hoveredWindow_;
        } else if (focusedWindow != hoveredWindow_) {
          focusWindow(hoveredWindow_);
          moveWindowToFront(hoveredWindow_);
        }

        if (canSubmitPointerButtonEvents) {
          hoveredWindow_.window.submitPointerButtonUpdate(PointerUpdate(
            pointer,
            event,
            (cursor.x - hoveredWindow_.window.drawingX).toDouble(),
            (cursor.y - hoveredWindow_.window.drawingY).toDouble(),
          ));
          isFocusedWindowFocusedFromPointer = true;
        }
      } else if (canSubmitPointerButtonEvents) {
        var window = focusedWindow;
        if (window != null && window.canReceiveInput) {
          if (isMovingFocusedWindow &&
              window.window.contentY < 0 &&
              window.isFreeFloating) {
            window.maximize();
          }

          window.window.submitPointerButtonUpdate(PointerUpdate(
            pointer,
            event,
            (cursor.x - window.window.drawingX).toDouble(),
            (cursor.y - window.window.drawingY).toDouble(),
          ));
        }
      }
    }

    if (!event.isPressed) {
      isGrabbingFocusedWindow = false;
      isMovingFocusedWindow = false;
      isResizingFocusedWindow = false;
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
        (cursor.x - window.window.drawingX).toDouble(),
        (cursor.y - window.window.drawingY).toDouble(),
      ));
    }
  };
  pointer.onRemove = (event) {
    inputDevices.remove(pointer);
    print("A 🖱️ pointer has been removed!");
    print("- Name: '${pointer.name}'");
  };
}

void handleWindowSwitching(KeyboardDevice keyboard) {
  if (!isSwitchingWindows) {
    isSwitchingWindows = true;
    cursorImage = null;
    windowSwitchIndex = 0;
    tempWindowList = windows.toList();
  }

  if (focusedWindow != null) {
    var direction = isShiftKeyPressed ? -1 : 1;
    windowSwitchIndex = (windowSwitchIndex + direction) % windows.length;
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
    print("Launching 🖥️ Terminal '$terminalProgram' ...");
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
    print("A ⌨️ keyboard has been removed!");
    print("- Name: '${keyboard.name}'");
  };
}

void handleNewInput(NewInputEvent event) {
  var pointer = event.pointer;
  var keyboard = event.keyboard;

  if (pointer != null) {
    inputDevices.add(pointer);
    print("A 🖱️ pointer has been added!");
    print("- Name: '${pointer.name}'");

    handleNewPointer(pointer);
  } else if (keyboard != null) {
    inputDevices.add(keyboard);
    print("A ⌨️ keyboard has been added!");
    print("- Name: '${keyboard.name}'");

    handleNewKeyboard(keyboard);
  }
}

void handleCursorImage(CursorImageEvent event) {
  cursorImage = event.image;
}

void main(List<String> arguments) async {
  var diamond_ = Waybright();
  diamond = diamond_;

  diamond_.onNewMonitor = handleNewMonitor;
  diamond_.onNewWindow = handleNewWindow;
  diamond_.onNewInput = handleNewInput;
  diamond_.onCursorImage = handleCursorImage;

  try {
    print("Loading 🖼️ wallpaper '$wallpaperImagePath'...");
    wallpaperImage = await diamond_.loadPngImage(wallpaperImagePath);
  } catch (e) {
    stderr.writeln("Failed to load 🖼️ wallpaper '$wallpaperImagePath': $e");
  }

  try {
    var socketName = diamond_.openSocket();
    print("~~~ Socket opened on '$socketName' ~~~");

    if (arguments.length == 2) {
      if (arguments[0] == "-p") {
        var program = arguments[1];
        print("Running program '$program' ...");
        try {
          Isolate.run(() => Process.runSync(program, []));
        } catch (e) {
          stderr.writeln("Failed to run program '$program': $e");
        }
      }
    }
  } catch (e) {
    print(e);
  }
}
