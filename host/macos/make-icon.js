// Draws the helper's 1024x1024 app icon (a white "lock.shield" SF Symbol on a blue rounded square)
// as a PNG, with AppKit through JavaScript for Automation: no image files or extra tools needed.
// Usage: osascript -l JavaScript make-icon.js <output.png>
ObjC.import('AppKit');

function run(argv) {
    const out = argv[0];
    const size = 1024;
    const rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
        null, size, size, 8, 4, true, false, 'NSDeviceRGBColorSpace', 0, 0);
    $.NSGraphicsContext.saveGraphicsState;
    $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));

    // Rounded square in the macOS icon grid (824 pt body on a 1024 pt canvas), with a soft shadow.
    const body = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(100, 100, 824, 824), 185, 185);
    $.NSGraphicsContext.saveGraphicsState;
    const shadow = $.NSShadow.alloc.init;
    shadow.shadowColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.3);
    shadow.shadowBlurRadius = 24;
    shadow.shadowOffset = $.NSMakeSize(0, -10);
    shadow.set;
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.10, 0.25, 0.56, 1).set;
    body.fill;
    $.NSGraphicsContext.restoreGraphicsState;
    const gradient = $.NSGradient.alloc.initWithStartingColorEndingColor(
        $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.10, 0.25, 0.56, 1),   // bottom
        $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.22, 0.52, 0.93, 1));  // top
    gradient.drawInBezierPathAngle(body, 90);

    // The symbol in white, scaled to about half the body height and centred.
    let symbol = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('lock.shield.fill', 'VPN');
    if (symbol.isNil()) throw new Error('SF Symbol lock.shield.fill is not available');
    let config = $.NSImageSymbolConfiguration.configurationWithPointSizeWeight(400, 0.23); // semibold
    config = config.configurationByApplyingConfiguration(
        // Palette layers: the lock in the background blue (so it reads as a cut-out), the shield white.
        $.NSImageSymbolConfiguration.configurationWithPaletteColors($([
            $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.15, 0.36, 0.76, 1), $.NSColor.whiteColor])));
    symbol = symbol.imageWithSymbolConfiguration(config);
    const scale = 470 / symbol.size.height;
    const w = symbol.size.width * scale, h = symbol.size.height * scale;
    symbol.drawInRectFromRectOperationFraction(
        $.NSMakeRect((size - w) / 2, (size - h) / 2, w, h), $.NSZeroRect, 2 /* source over */, 1);

    $.NSGraphicsContext.restoreGraphicsState;
    const png = rep.representationUsingTypeProperties(4 /* PNG */, $({}));
    if (!png.writeToFileAtomically(out, true)) throw new Error('could not write ' + out);
    return out;
}
