package io.github.humbleui.skija;

import lombok.AllArgsConstructor;
import lombok.Data;
import lombok.With;
import org.jetbrains.annotations.ApiStatus;

@Data @With
public class GradientStyle {
    @ApiStatus.Internal public static final int _INTERPOLATE_PREMUL = 1;
    public static GradientStyle DEFAULT = new GradientStyle(FilterTileMode.CLAMP, true, null, 0, 0);

    @ApiStatus.Internal public final FilterTileMode _tileMode;
    @ApiStatus.Internal public final boolean _premul;
    @ApiStatus.Internal public final Matrix33 _localMatrix;
    @ApiStatus.Internal public final int _interpColorSpace;   // maps to Interpolation::ColorSpace enum (0-14)
    @ApiStatus.Internal public final int _interpHueMethod;    // maps to Interpolation::HueMethod enum (0-3)

    public GradientStyle(FilterTileMode tileMode, boolean premul, Matrix33 localMatrix, int interpColorSpace, int interpHueMethod) {
        this._tileMode = tileMode;
        this._premul = premul;
        this._localMatrix = localMatrix;
        this._interpColorSpace = interpColorSpace;
        this._interpHueMethod = interpHueMethod;
    }

    /** Backward-compatible constructor (defaults to Destination color space, Shorter hue method). */
    public GradientStyle(FilterTileMode tileMode, boolean premul, Matrix33 localMatrix) {
        this(tileMode, premul, localMatrix, 0, 0);
    }

    @ApiStatus.Internal
    public int _getFlags() {
        return 0 | (_premul ? _INTERPOLATE_PREMUL : 0);
    }

    @ApiStatus.Internal
    public float[] _getMatrixArray() {
        return _localMatrix == null ? null : _localMatrix.getMat();
    }
}
