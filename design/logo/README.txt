Paperlight logo pack — concept 1b (P-Page)

COLOURS
Red Orange  #F42902  dominant (~70% of surface)
Snowy White #FDFDFF  the mark
Yellow Punk #D4FF00  corner chip + i-dot only; never on white
Black       #000000  night-mode ground

SVG
paperlight-icon.svg          rounded tile (legacy / general use)
paperlight-icon-square.svg   full-bleed master (Play Store)
adaptive-foreground.svg      108dp layer, artwork inside 66dp safe zone
adaptive-background.svg      solid Red Orange
adaptive-monochrome.svg      Android 13+ themed icon (single colour)
splash-mark.svg              240dp, artwork inside 160dp circle
notification-icon.svg        24dp white silhouette
favicon.svg                  32px tile
wordmark-*.svg               outlined Archivo Black
lockup-{horizontal,stacked}-on-{red,white,black}.svg

PNG
android/res/mipmap-*/ic_launcher.png        48/72/96/144/192
android/res/drawable-*/ic_stat_paperlight.png  24/36/48/72/96
png/store-icon-512.png, png/favicon-32.png

RULES
Clear space = width of the P's stem on all sides.
Min sizes: icon 48px (24px silhouette below that); horizontal lockup 120px wide; stacked 72px; wordmark 80px.
Splash: windowSplashScreenBackground #F42902 (day) / #000000 (night), splash-mark.svg as icon, no icon background.
