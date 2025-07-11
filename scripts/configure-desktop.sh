#!/bin/bash
#
# Desktop Configuration Script for ArchonOS
# Configures KDE Plasma with plain default theme and performance optimizations
#

# Strict error handling
set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[DESKTOP-INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[DESKTOP-SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[DESKTOP-WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[DESKTOP-ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${BLUE}[DESKTOP-STEP]${NC} $*" >&2
}

configure_kde_plasma() {
    log_step "Configuring KDE Plasma desktop (plain theme)"
    
    # Create KDE configuration directory
    mkdir -p /home/archon/.config
    
    # Configure KDE with plain default theme
    cat > /home/archon/.config/kdeglobals << EOF
[KDE]
SingleClick=false
LookAndFeelPackage=org.kde.breeze.desktop

[General]
ColorScheme=Breeze
Name=Breeze
shadeSortColumn=true

[Icons]
Theme=breeze

[WM]
activeBackground=252,252,252
activeBlend=255,255,255
activeForeground=35,38,41
inactiveBackground=239,240,241
inactiveBlend=255,255,255
inactiveForeground=112,125,138
EOF

    # Configure compositor for performance
    cat > /home/archon/.config/kwinrc << EOF
[Compositing]
AnimationSpeed=3
Backend=OpenGL
Enabled=true
GLColorCorrection=false
GLCore=false
GLPlatformInterface=glx
GLPreferBufferSwap=a
GLTextureFilter=1
HideCursor=true
OpenGLIsUnsafe=false
UnredirectFullscreen=true
WindowsBlockCompositing=true
XRenderSmoothScale=false

[Desktops]
Id_1=87fcc8ee-8eff-4c81-9a96-2b8b4b1e5a7f
Number=1
Rows=1

[Effect-Blur]
BlurStrength=5
NoiseStrength=0

[Effect-DesktopGrid]
BorderWidth=0

[Effect-PresentWindows]
BorderActivate=9

[Effect-Slide]
Duration=150

[Effect-Zoom]
InitialZoom=1

[Windows]
AutoRaise=false
AutoRaiseInterval=750
BorderSnapZone=10
CenterSnapZone=0
DelayFocusInterval=300
ElectricBorderCooldown=350
ElectricBorderCornerRatio=0.25
ElectricBorderDelay=150
ElectricBorderMaximize=true
ElectricBorderTiling=true
ElectricBorders=0
FocusPolicy=ClickToFocus
FocusStealingPreventionLevel=1
GeometryTip=false
HideUtilityWindowsForInactive=true
InactiveTabsSkipTaskbar=false
MaximizeButtonLeftClickCommand=Maximize
MaximizeButtonMiddleClickCommand=Maximize (vertical only)
MaximizeButtonRightClickCommand=Maximize (horizontal only)
NextFocusPrefersMouse=false
Placement=Smart
SeparateScreenFocus=false
ShadeHover=false
ShadeHoverInterval=250
SnapOnlyWhenOverlapping=false
TitlebarDoubleClickCommand=Maximize
WindowSnapZone=10
EOF

    # Configure simple desktop layout
    cat > /home/archon/.config/plasma-org.kde.plasma.desktop-appletsrc << EOF
[ActionPlugins][0]
RightButton;NoModifier=org.kde.contextmenu
wheel:Vertical;NoModifier=org.kde.switchdesktop

[ActionPlugins][1]
RightButton;NoModifier=org.kde.contextmenu

[Containments][1]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=4
plugin=org.kde.plasma.private.systemtray
wallpaperplugin=org.kde.image

[Containments][1][Applets][2]
immutability=1
plugin=org.kde.plasma.devicenotifier

[Containments][1][Applets][3]
immutability=1
plugin=org.kde.plasma.manage-inputmethod

[Containments][1][Applets][4]
immutability=1
plugin=org.kde.plasma.notifications

[Containments][1][Applets][5]
immutability=1
plugin=org.kde.plasma.keyboardlayout

[Containments][1][Applets][6]
immutability=1
plugin=org.kde.plasma.keyboardindicator

[Containments][1][Applets][7]
immutability=1
plugin=org.kde.plasma.clipboard

[Containments][1][Applets][8]
immutability=1
plugin=org.kde.plasma.volume

[Containments][1][Applets][9]
immutability=1
plugin=org.kde.plasma.battery

[Containments][1][Applets][10]
immutability=1
plugin=org.kde.plasma.networkmanagement

[Containments][1][Applets][11]
immutability=1
plugin=org.kde.plasma.bluetooth

[Containments][1][General]
extraItems=org.kde.plasma.devicenotifier,org.kde.plasma.manage-inputmethod,org.kde.plasma.notifications,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.clipboard,org.kde.plasma.volume,org.kde.plasma.battery,org.kde.plasma.networkmanagement,org.kde.plasma.bluetooth
knownItems=org.kde.plasma.devicenotifier,org.kde.plasma.manage-inputmethod,org.kde.plasma.notifications,org.kde.plasma.keyboardlayout,org.kde.plasma.keyboardindicator,org.kde.plasma.clipboard,org.kde.plasma.volume,org.kde.plasma.battery,org.kde.plasma.networkmanagement,org.kde.plasma.bluetooth

[Containments][2]
activityId=87fcc8ee-8eff-4c81-9a96-2b8b4b1e5a7f
formfactor=0
immutability=1
lastScreen=0
location=0
plugin=org.kde.plasma.desktop
wallpaperplugin=org.kde.image

[Containments][2][Wallpaper][org.kde.image][General]
Image=file:///usr/share/wallpapers/Breeze/contents/images/1920x1080.png
SlidePaths=/usr/share/wallpapers/

[Containments][3]
activityId=
formfactor=2
immutability=1
lastScreen=0
location=3
plugin=org.kde.panel
wallpaperplugin=org.kde.image

[Containments][3][Applets][4]
immutability=1
plugin=org.kde.plasma.kickoff

[Containments][3][Applets][5]
immutability=1
plugin=org.kde.plasma.pager

[Containments][3][Applets][6]
immutability=1
plugin=org.kde.plasma.icontasks

[Containments][3][Applets][7]
immutability=1
plugin=org.kde.plasma.marginsseparator

[Containments][3][Applets][8]
immutability=1
plugin=org.kde.plasma.systemtray

[Containments][3][Applets][8][Configuration]
SystrayContainmentId=1

[Containments][3][Applets][9]
immutability=1
plugin=org.kde.plasma.digitalclock

[Containments][3][Applets][10]
immutability=1
plugin=org.kde.plasma.showdesktop

[Containments][3][General]
AppletOrder=4;5;6;7;8;9;10

[ScreenMapping]
itemsOnDisabledScreens=
screenMapping=
EOF

    # Set ownership
    chown -R archon:archon /home/archon/.config
    
    log_success "KDE Plasma desktop configured with plain theme"
}

configure_sddm_theme() {
    log_step "Configuring SDDM (plain theme)"
    
    # Configure SDDM to use default plain theme
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/theme.conf << EOF
[Theme]
Current=breeze
EOF
    
    log_success "SDDM plain theme configured"
}

configure_performance_plasma() {
    log_step "Configuring Plasma performance optimizations"
    
    # Create performance configuration for Plasma
    cat > /home/archon/.config/plasmarc << EOF
[PlasmaViews][Panel 1]
floating=0
panelVisibility=0

[PlasmaViews][Panel 1][Defaults]
thickness=36

[Theme]
name=breeze

[Wallpapers]
usersWallpapers=
EOF

    # Configure KDE wallet to not autostart
    cat > /home/archon/.config/kwalletrc << EOF
[Wallet]
Enabled=false
First Use=false
EOF

    # Configure Baloo file indexing (disable for performance)
    cat > /home/archon/.config/baloofilerc << EOF
[Basic Settings]
Indexing-Enabled=false
EOF

    # Configure KDE startup
    cat > /home/archon/.config/ksmserverrc << EOF
[General]
loginMode=default
screenCount=1
EOF

    # Set ownership
    chown -R archon:archon /home/archon/.config
    
    log_success "Plasma performance optimizations configured"
}

# Main execution
main() {
    log_info "Starting plain desktop configuration"
    
    configure_kde_plasma
    configure_sddm_theme
    configure_performance_plasma
    
    log_success "Plain desktop configuration completed"
}

# Execute main function
main "$@"