// Some parts taken from https://github.com/GreenLightning/gpu-font-rendering/

override show_control_points: bool = false;
override show_segments: bool = false;
override show_em_uv: bool = false;

/// The control points of the glyphs in contour order.
/// End points are duplicated for shader simplicity.
@group(0) @binding(0)
var<storage, read> glyph_points: array<vec2<f32>>;

// TODO: make this a `array<u16>`
/// The curves belonging to each band segment.
/// Each curve is a single index to the first point in the curve.
@group(0) @binding(1) 
var<storage, read> glyph_band_segment_curves: array<u32>;

struct BandSegmentInstance {
    @location(0) top_left: vec2<f32>,
    @location(1) size: vec2<f32>,

    @location(2) em_window_top_left: vec2<f32>,
    @location(3) em_window_size: vec2<f32>,
    @location(4) segment_begin: i32,
    @location(5) segment_length: u32,
};

struct VertexOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) em_uv: vec2<f32>,
    @location(1) @interpolate(flat) segment_begin: i32,
    @location(2) @interpolate(flat) segment_length: u32,
}

@vertex fn vertex_main(
    instance: BandSegmentInstance,
    @builtin(vertex_index) v_index: u32,
) -> VertexOut {
    var out: VertexOut;

    let indicator = array(
        vec2f(0, 0),
        vec2f(0, -1),
        vec2f(1, 0),
        vec2f(1, 0),
        vec2f(0, -1),
        vec2f(1, -1),
    )[v_index];
    let pos = instance.top_left + abs(indicator) * instance.size;
    out.pos = vec4<f32>(pos, 0.0, 1.0);

    // var tl = instance.em_window_top_left;
    // tl.y = -(tl.y - 1);
    out.em_uv = instance.em_window_top_left + indicator * instance.em_window_size;

    out.segment_begin = instance.segment_begin;
    out.segment_length = instance.segment_length;

    return out;
}

fn rand(p: f32) -> f32 {
    return rand2d(vec2f(p));
}

fn rand2d(p: vec2f) -> f32 {
    let K1 = vec2f(
        23.14069263277926, // e^pi (Gelfond's constant)
         2.665144142690225 // 2^sqrt(2) (Gelfondâ€“Schneider constant)
    );
    return fract(cos(dot(p, K1)) * 12345.6789);
}

fn rand_color(p: f32) -> vec3f {
    let rand_1 = rand(p);
    let rand_2 = rand(p + 1.4398);
    let rand_3 = rand(p + 2.123);
    return vec3f(rand_1, rand_2, rand_3);
}

fn compute_coverage(
    inverse_sample_diameter: f32,
    p1: vec2<f32>,
    p2: vec2<f32>,
    p3: vec2<f32>,
) -> f32 {
    if (p1.y > 0 && p2.y > 0 && p3.y > 0) { return 0; }
    if (p1.y < 0 && p2.y < 0 && p3.y < 0) { return 0; }

    // NOTE: Simplified from abc formula by extracting a factor of (-2) from b.
    let a = p1 - 2*p2 + p3;
    let b = p1 - p2;
    let c = p1;

    var t0 = 0.0;
    var t1 = 0.0;

    if (any(a * b >= vec2f(3e-7))) {
        // Quadratic segment, solve abc formula to find roots.
        let radicand = b.y*b.y - a.y*c.y;
        if (radicand <= 0) { return 0; }

        let s = sqrt(radicand);
        t0 = (b.y - s) / a.y;
        t1 = (b.y + s) / a.y;
    } else {
        let t = p1.y / (p1.y - p3.y);
        if (p1.y < p3.y) {
            t0 = -1.0;
            t1 = t;
        } else {
            t0 = t;
            t1 = -1.0;
        }
    }

    var alpha = 0.0;
    if (0 <= t0 && t0 < 1) {
        let x = (a.x*t0 - 2.0*b.x)*t0 + c.x;
        alpha += clamp(x * inverse_sample_diameter + 0.5, 0.0, 1.0);
    }

    if (0 <= t1 && t1 < 1) {
        let x = (a.x*t1 - 2.0*b.x)*t1 + c.x;
        alpha -= clamp(x * inverse_sample_diameter + 0.5, 0.0, 1.0);
    }
    return alpha;
}

@fragment fn frag_main(vert: VertexOut) -> @location(0) vec4<f32> {
    let segment_begin = u32(abs(vert.segment_begin));
    let em_uv = vert.em_uv;

    let fw = fwidth(em_uv);
    let inverse_sample_diameter = 1.0 / (1.4*fw);

    var alpha = 0.0;

    for (var i = 0u; i < vert.segment_length; i++) {
        let curve_begin = glyph_band_segment_curves[segment_begin + i];

        // == Compute sample coverage by the curve == //

        var p1 = glyph_points[curve_begin] - em_uv;
        var p2 = glyph_points[curve_begin + 1u] - em_uv;
        var p3 = glyph_points[curve_begin + 2u] - em_uv;

        // rotate if is vertical band segment
        if (vert.segment_begin < 0) {
            p1 = vec2f(p1.y, -p1.x);
            p2 = vec2f(p2.y, -p2.x);
            p3 = vec2f(p3.y, -p3.x);
        }

        alpha += compute_coverage(inverse_sample_diameter.x, p1, p2, p3);

        if (show_control_points) {
            // Visualize control points.
            let r = 3.0 * 0.5 * (fw.x + fw.y);

            if ((dot(p1, p1) < r*r || dot(p3, p3) < r*r) && (dot(p2, p2) < r*r)) {
                return vec4<f32>(0, 0, 1, 1);
            }
            if (dot(p1, p1) < r*r || dot(p3, p3) < r*r) {
                return vec4<f32>(0, 1, 0, 1);;
            }

            if (dot(p2, p2) < r*r) {
                return vec4<f32>(1, 0, 1, 1);
            }
        }
    }

    alpha = clamp(alpha, 0.0, 1.0);
    // We expect the fractional area to be further antialiased by a band in the
    // other axis. So we halve our contribution.
    alpha = floor(alpha) + fract(alpha) * 0.5;

    var glyph = vec4<f32>(0.0, 0.0, 0.0, alpha);

    if (show_em_uv) {
        glyph.x = em_uv.x;
        glyph.y = em_uv.y;
    }

    if (show_segments) {
        let seg = vec4<f32>(rand_color(f32(vert.segment_begin)), 0.5);
        let color_o = glyph.xyz + seg.xyz * (1.0 - glyph.w);
        let alpha_o = glyph.w + seg.w * (1.0 - glyph.w);
        return vec4<f32>(color_o, alpha_o);
    }

    return glyph;

    // let xy_even = floor(vert.uv * 6.0) % 2.0;
    // return vec4<f32>(1.0, 0.0, 1.0, abs(xy_even.x - xy_even.y));
}
