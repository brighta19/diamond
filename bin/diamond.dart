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
  Window window;

  var popups = WindowList();
  var unmaximizedPosition = Vector(0.0, 0.0);
  var unmaximizedSize = Vector(0.0, 0.0);
  var isMaximizingFocusedWindow = false;
  var isUnmaximizingFocusedWindow = false;
  var isFullscreeningFocusedWindow = false;
  var isUnfullscreeningFocusedWindow = false;
  var wasMaximizedBeforeFullscreened = false;

  bool get isFreeFloating => !window.isMaximized && !window.isFullscreen;

  DiamondWindow(this.window) {
    var appId = window.appId;
    var title = window.title;

    window.onRemove = (event) {
      windows.remove(window);
      diamondWindows.remove(window);

      print("${appId.isEmpty ? "An application" : "Application `$appId`"}"
          "'s 🪟${window.isPopup ? " popup" : ""} window has been removed!");
    };

    window.onShow = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " shown!");

      focusWindow(window);
    };

    window.onHide = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " hidden!");

      if (window == focusedWindow) {
        unfocusWindow();

        var nextWindow = windows.getNextWindow(window);
        if (nextWindow != null) focusWindow(nextWindow);
      }
    };

    // The window wants to be moved, which has to be handled manually.
    window.onMove = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " moved!");

      if (!window.isFullscreen) {
        isGrabbingFocusedWindow = true;
        cursorPositionAtGrab.x = cursor.x;
        cursorPositionAtGrab.y = cursor.y;
        windowDrawingPositionAtGrab.x = window.drawingX;
        windowDrawingPositionAtGrab.y = window.drawingY;
      }

      focusWindow(window);
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
          " ${window.isMaximized ? "un" : ""}maximized!");

      if (window.isMaximized) {
        unmaximize();
      } else {
        maximize();
      }
    };

    // The window wants to be fullscreened, which has to be handled manually.
    window.onFullscreen = (event) {
      print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
          " wants ${title.isEmpty ? "its 🪟 window" : "the 🪟 window '$title'"}"
          " ${window.isFullscreen ? "un" : ""}fullscreened!");

      if (window.isFullscreen) {
        unfullscreen();
      } else {
        fullscreen();
      }
    };

    window.onNewPopup = handleNewPopup;
  }

  void maximize() {
    if (isMaximizingFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (window.isFullscreen) {
      window.unfullscreen();
      print("Unfullscreening 🪟 window before maximizing...");
    } else {
      unmaximizedPosition.x = window.drawingX;
      unmaximizedPosition.y = window.drawingY;
      unmaximizedSize.x = window.contentWidth;
      unmaximizedSize.y = window.contentHeight;
    }
    window.maximize(width: monitor.mode.width, height: monitor.mode.height);
    isMaximizingFocusedWindow = true;
  }

  void unmaximize() {
    if (isUnmaximizingFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = unmaximizedSize.x.toInt();
    var height = unmaximizedSize.y.toInt();
    window.unmaximize(width: width, height: height);
    isUnmaximizingFocusedWindow = true;
  }

  void fullscreen() {
    if (isFullscreeningFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    if (window.isMaximized) {
      window.unmaximize();
      wasMaximizedBeforeFullscreened = true;
      print("Unmaximizing 🪟 window before fullscreening...");
    } else {
      unmaximizedPosition.x = window.drawingX;
      unmaximizedPosition.y = window.drawingY;
      unmaximizedSize.x = window.contentWidth;
      unmaximizedSize.y = window.contentHeight;
      wasMaximizedBeforeFullscreened = false;
    }
    window.fullscreen(width: monitor.mode.width, height: monitor.mode.height);
    isFullscreeningFocusedWindow = true;
  }

  void unfullscreen() {
    if (isUnfullscreeningFocusedWindow) return;

    var monitor = currentMonitor;
    if (monitor == null) throw NoMonitorFoundException();

    var width = unmaximizedSize.x.toInt();
    var height = unmaximizedSize.y.toInt();
    window.unfullscreen(width: width, height: height);
    isUnfullscreeningFocusedWindow = true;

    if (wasMaximizedBeforeFullscreened) {
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

  void update() {
    if (isMaximizingFocusedWindow) {
      if (window.isMaximized) {
        isMaximizingFocusedWindow = false;
        updatePosition();
        print("Maximized 🪟 window!");
      }
    } else if (isUnmaximizingFocusedWindow) {
      if (!window.isMaximized) {
        isUnmaximizingFocusedWindow = false;
        updatePosition();
        print("Unmaximized 🪟 window!");
      }
    } else if (isFullscreeningFocusedWindow) {
      if (window.isFullscreen) {
        isFullscreeningFocusedWindow = false;
        updatePosition();
        print("Fullscreened 🪟 window!");
      }
    } else if (isUnfullscreeningFocusedWindow) {
      if (!window.isFullscreen) {
        isUnfullscreeningFocusedWindow = false;
        updatePosition();
        print("Unfullscreened 🪟 window!");
      }
    }
  }
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
var windows = WindowList();
var diamondWindows = <Window, DiamondWindow>{};
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
var tempWindowList = <Window>[];

var readyToQuit = false;

var isLeftAltKeyPressed = false;
var isRightAltKeyPressed = false;
bool get isAltKeyPressed => isLeftAltKeyPressed || isRightAltKeyPressed;
var isLeftShiftKeyPressed = false;
var isRightShiftKeyPressed = false;
bool get isShiftKeyPressed => isLeftShiftKeyPressed || isRightShiftKeyPressed;

bool get shouldSubmitPointerMoveEvents =>
    !isSwitchingWindows && !isBackgroundFocusedFromPointer;

Window? focusedWindow;
Window? get hoveredWindow => getHoveredWindowFromList(windows);

double getDistanceBetweenPoints(Vector point1, Vector point2) {
  var x = point1.x - point2.x;
  var y = point1.y - point2.y;
  return sqrt(x * x + y * y);
}

void focusWindow(Window window) {
  if (focusedWindow == window) return;
  print("Redirecting 🪟 window 🔎 focus...");

  if (focusedWindow != null) {
    focusedWindow?.unfocus();
  }

  window.focus();
  windows.moveToFront(window);
  focusedWindow = window;
}

void unfocusWindow() {
  if (focusedWindow == null) return;
  print("🔎 Unfocusing 🪟 window...");

  focusedWindow?.unfocus();
  focusedWindow = null;
}

bool isCursorOnWindow(Window window) {
  return window.contentX <= cursor.x &&
      window.contentY <= cursor.y &&
      window.contentX + window.contentWidth >= cursor.x &&
      window.contentY + window.contentHeight >= cursor.y;
}

Window? getHoveredWindowFromList(WindowList windows) {
  var listIterable = windows.frontToBackIterable;
  for (var window in listIterable) {
    var diamondWindow = diamondWindows[window]!;
    var popupList = diamondWindow.popups;

    var popup = getHoveredWindowFromList(popupList);
    if (popup != null) return popup;

    if (isCursorOnWindow(window)) return window;
  }

  return null;
}

void drawCursor(Renderer renderer) {
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

void drawBorder(Renderer renderer, num x, num y, int width, int height,
    int color, int borderWidth) {
  renderer.fillStyle = color;

  var x0 = (x - borderWidth).toInt();
  var y0 = (y - borderWidth).toInt();
  var width0 = width + borderWidth * 2;
  var height0 = height + borderWidth * 2;

  renderer.fillRect(x0, y0, width0 - borderWidth, borderWidth);
  renderer.fillRect(
      x0 + width0 - borderWidth, y0, borderWidth, height0 - borderWidth);
  renderer.fillRect(x0 + borderWidth, y0 + height0 - borderWidth,
      width0 - borderWidth, borderWidth);
  renderer.fillRect(x0, y0 + borderWidth, borderWidth, height0 - borderWidth);
}

void drawPopups(Renderer renderer, Window window) {
  var diamondWindow = diamondWindows[window]!;
  var list = diamondWindow.popups.backToFrontIterable;

  for (var popup in list) {
    renderer.drawWindow(popup, popup.drawingX, popup.drawingY);
    drawPopups(renderer, popup);
  }
}

void drawWindows(Renderer renderer) {
  var numberOfWindows = windows.length;

  if (numberOfWindows == 0) return;

  if (numberOfWindows == 1) {
    var window = windows.first;
    if (window.isVisible) {
      var borderColor = 0xff0000ff;
      var diamondWindow = diamondWindows[window]!;
      diamondWindow.update();
      drawWindow(renderer, window, borderColor);
    }
    return;
  }

  var addend = 0xff ~/ (numberOfWindows - 1);

  var red = 0x00;
  var blue = 0xff;

  var list = windows.backToFrontIterable;
  for (var window in list) {
    if (window.isVisible) {
      var borderColor = (red << 24) | (blue << 8) | 0x77;
      var diamondWindow = diamondWindows[window]!;
      diamondWindow.update();
      drawWindow(renderer, window, borderColor);
    }
    blue -= addend;
    red += addend;
  }
}

void drawWindow(Renderer renderer, Window window, int borderColor) {
  var borderWidth = 2;

  var diamondWindow = diamondWindows[window]!;
  if (diamondWindow.isFreeFloating) {
    drawBorder(
      renderer,
      window.contentX,
      window.contentY,
      window.contentWidth,
      window.contentHeight,
      borderColor,
      borderWidth,
    );
  }
  renderer.drawWindow(window, window.drawingX, window.drawingY);
  drawPopups(renderer, window);
}

void drawWallpaper(Renderer renderer) {
  var monitor = currentMonitor;
  if (monitor == null) throw NoMonitorFoundException();

  if (wallpaperImage != null) {
    var monitorWidth = monitor.mode.width;
    var monitorHeight = monitor.mode.height;
    var imageWidth = 1920;
    // var imageHeight = 1080;

    var scale = monitorWidth / imageWidth;

    var x = (monitorWidth - imageWidth * scale) ~/ 2;
    var y = 0;
    var width = (imageWidth * scale).toInt();
    var height = monitorHeight;

    renderer.drawImage(wallpaperImage!, x, y, width, height);
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

void handleNewPopup(NewPopupWindowEvent event) {
  print("A 🪟 popup window has been added!");

  var window = event.window;
  var parent = window.parent;
  if (parent == null) return;

  var diamondWindow = DiamondWindow(window);
  diamondWindows[window] = diamondWindow;

  var parentDiamondWindow = diamondWindows[parent]!;
  parentDiamondWindow.popups.addToFront(window);

  window.onRemove = (event) {
    diamondWindows.remove(window);
    parentDiamondWindow.popups.remove(window);
  };

  window.onShow = (event) {
    window.drawingX = window.popupX + parent.contentX;
    window.drawingY = window.popupY + parent.contentY;
  };

  window.onNewPopup = handleNewPopup;
}

void handleNewWindow(NewWindowEvent event) {
  Window window = event.window;
  windows.addToFront(window);

  var diamondWindow = DiamondWindow(window);
  diamondWindows[window] = diamondWindow;

  final appId = window.appId;
  final title = window.title;

  print("${appId.isEmpty ? "An application" : "Application '$appId'"}"
      "'s 🪟${window.isPopup ? " popup" : ""} window has been added!");

  if (title.isNotEmpty) print("- Title: '$title'");
}

void handleWindowHover(PointerMoveEvent event) {
  if (!shouldSubmitPointerMoveEvents) return;
  var pointer = event.pointer;

  var window = focusedWindow;
  if (isFocusedWindowFocusedFromPointer && window != null) {
    window.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.x - window.drawingX).toDouble(),
      (cursor.y - window.drawingY).toDouble(),
    ));
    return;
  }

  Window? hoveredWindow_ = hoveredWindow;
  if (hoveredWindow_ != null) {
    hoveredWindow_.submitPointerMoveUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.x - hoveredWindow_.drawingX).toDouble(),
      (cursor.y - hoveredWindow_.drawingY).toDouble(),
    ));
    return;
  }
}

void handleWindowMove() {
  focusedWindow?.drawingX =
      windowDrawingPositionAtGrab.x + cursor.x - cursorPositionAtGrab.x;
  focusedWindow?.drawingY =
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

  window.drawingX = x;
  window.drawingY = y;
  window.submitNewSize(width: width.toInt(), height: height.toInt());
}

void handlePointerMovement(PointerMoveEvent event) {
  var window = focusedWindow;
  if (window != null && isGrabbingFocusedWindow) {
    var distance = getDistanceBetweenPoints(cursorPositionAtGrab, cursor);
    if (distance >= 15) {
      if (window.isMaximized) {
        var diamondWindow = diamondWindows[window]!;
        diamondWindow.unmaximize();
      }
      isMovingFocusedWindow = true;
      window.submitPointerMoveUpdate(PointerUpdate(
        event.pointer,
        event,
        (cursor.x - window.drawingX).toDouble(),
        (cursor.y - window.drawingY).toDouble(),
      ));
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
    Window? hoveredWindow_ = hoveredWindow;

    if (hoveredWindow_ == null) {
      if (event.isPressed) {
        focusOnBackground();
      } else {
        if (isFocusedWindowFocusedFromPointer) {
          var window = focusedWindow;
          if (window != null) {
            window.submitPointerButtonUpdate(PointerUpdate(
              pointer,
              event,
              (cursor.x - window.drawingX).toDouble(),
              (cursor.y - window.drawingY).toDouble(),
            ));
          }
        }
      }
    } else {
      if (event.isPressed) {
        if (hoveredWindow_.isPopup) {
          hoveredWindow_.focus();
          focusedWindow = hoveredWindow_;
        } else if (focusedWindow != hoveredWindow_) {
          focusWindow(hoveredWindow_);
        }

        hoveredWindow_.submitPointerButtonUpdate(PointerUpdate(
          pointer,
          event,
          (cursor.x - hoveredWindow_.drawingX).toDouble(),
          (cursor.y - hoveredWindow_.drawingY).toDouble(),
        ));
        isFocusedWindowFocusedFromPointer = true;
      } else {
        var window = focusedWindow;
        if (window != null) {
          var diamondWindow = diamondWindows[window]!;
          if (isMovingFocusedWindow &&
              window.contentY < 0 &&
              diamondWindow.isFreeFloating) {
            var diamondWindow = diamondWindows[window]!;
            diamondWindow.maximize();
          }

          window.submitPointerButtonUpdate(PointerUpdate(
            pointer,
            event,
            (cursor.x - window.drawingX).toDouble(),
            (cursor.y - window.drawingY).toDouble(),
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
    Window? hoveredWindow_ = hoveredWindow;
    hoveredWindow_?.submitPointerAxisUpdate(PointerUpdate(
      pointer,
      event,
      (cursor.x - hoveredWindow_.drawingX).toDouble(),
      (cursor.y - hoveredWindow_.drawingY).toDouble(),
    ));
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
    windowSwitchIndex = 0;
    tempWindowList = windows.frontToBackIterable.toList();
  }

  if (focusedWindow != null) {
    var direction = isShiftKeyPressed ? -1 : 1;
    windowSwitchIndex = (windowSwitchIndex + direction) % windows.length;
  }

  if (windows.isNotEmpty) {
    try {
      var window = tempWindowList.elementAt(windowSwitchIndex);
      focusWindow(window);
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

void handleNewKeyboard(KeyboardDevice keyboard) {
  keyboard.onKey = (event) {
    updateKeys(event);

    if (event.key == InputDeviceButton.escape && event.isPressed) {
      if (readyToQuit) {
        quit();
      } else if (isAltKeyPressed) {
        readyToQuit = true;
      }
    } else if (event.key == InputDeviceButton.tab && event.isPressed) {
      if (isAltKeyPressed) {
        handleWindowSwitching(keyboard);
      }
    } else if (event.key == InputDeviceButton.keyT && event.isPressed) {
      if (isAltKeyPressed) {
        launchTerminal();
      }
    }

    if (!isAltKeyPressed) {
      isSwitchingWindows = false;
      readyToQuit = false;
    }

    if (!isSwitchingWindows) {
      focusedWindow?.submitKeyboardKeyUpdate(KeyboardUpdate(
        keyboard,
        event,
      ));
    }
  };
  keyboard.onModifiers = (event) {
    focusedWindow?.submitKeyboardModifiersUpdate(KeyboardUpdate(
      keyboard,
      event,
    ));
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

void main(List<String> arguments) async {
  var diamond_ = Waybright();
  diamond = diamond_;

  diamond_.onNewMonitor = handleNewMonitor;
  diamond_.onNewWindow = handleNewWindow;
  diamond_.onNewInput = handleNewInput;

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
