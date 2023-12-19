// Some parts taken from https://github.com/GreenLightning/gpu-font-rendering/

override show_control_points: bool = true;
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

struct GlyphWindow {
    @location(0) top_left: vec2<f32>,
    @location(1) size: vec2<f32>,

    @location(2) em_window_top_left: vec2<f32>,
    @location(3) em_window_size: vec2<f32>,
    @location(4) vert_curves_begin: u32,
    @location(5) hori_curves_begin: u32,
    @location(6) vh_curves_lengths: u32, // two u16s (vert, hori)
};

struct VertexOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) em_uv: vec2<f32>,
    @location(1) @interpolate(flat) vert_curves_begin: u32,
    @location(2) @interpolate(flat) hori_curves_begin: u32,
    @location(3) @interpolate(flat) vh_curves_lengths: u32, // two u16s (vert, hori)
}

@vertex fn vertex_main(
    instance: GlyphWindow,
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

    out.vert_curves_begin = instance.vert_curves_begin;
    out.hori_curves_begin = instance.hori_curves_begin;
    out.vh_curves_lengths = instance.vh_curves_lengths;

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

fn rand_color_2d(p: vec2f) -> vec3f {
    let rand_1 = rand2d(p);
    let rand_2 = rand2d(p + vec2f(1.4398, 9.312));
    let rand_3 = rand2d(p + vec2f(2.123, 3.348));
    return vec3f(rand_1, rand_2, rand_3);
}

fn compute_coverage_for_curve(
    inverse_sample_diameter: f32,
    p0: vec2<f32>,
    p1: vec2<f32>,
    p2: vec2<f32>,
) -> f32 {
    if (p0.y > 0 && p1.y > 0 && p2.y > 0) { return 0; }
    if (p0.y < 0 && p1.y < 0 && p2.y < 0) { return 0; }

    // NOTE: Simplified from abc formula by extracting a factor of (-2) from b.
    let a = p0 - 2*p1 + p2;
    let b = p0 - p1;
    let c = p0;

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
        let t = p0.y / (p0.y - p2.y);
        if (p0.y < p2.y) {
            t0 = -1.0;
            t1 = t;
        } else {
            t0 = t;
            t1 = -1.0;
        }
    }

    var alpha: f32 = 0.0;
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

fn compute_corverage(
    is_vertical_curve_band: bool,
    curves_begin: u32,
    curves_length: u32,
    inv_sample_diam: f32,
    em_uv: vec2<f32>,
) -> f32 {
    var alpha: f32 = 0.0;

    for (var i = 0u; i < curves_length; i++) {
        let curve_begin = glyph_band_segment_curves[curves_begin + i];

        // == Compute sample coverage by the curve == //

        var p0 = glyph_points[curve_begin] - em_uv;
        var p1 = glyph_points[curve_begin + 1u] - em_uv;
        var p2 = glyph_points[curve_begin + 2u] - em_uv;

        if (is_vertical_curve_band) {
            // rotate
            p0 = vec2f(p0.y, -p0.x);
            p1 = vec2f(p1.y, -p1.x);
            p2 = vec2f(p2.y, -p2.x);
        }

        alpha += compute_coverage_for_curve(inv_sample_diam, p0, p1, p2);

    }

    return alpha;
}


const PKIND_NONE: u32 = 0;
const PKIND_P0: u32 = 1;
const PKIND_P1: u32 = 1 << 1;
const PKIND_P2: u32 = 1 << 2;
struct PKindRes {
    pkind: u32,
    dist: f32,
}

fn get_control_point_kind(
    vert_curves_begin: u32,
    vert_curves_length: u32,
    hori_curves_begin: u32,
    hori_curves_length: u32,
    em_uv: vec2<f32>,
    radius: f32,
) -> PKindRes {
    var pkind = PKIND_NONE;
    var dist: f32 = 1e30;
    let curves_begin = array(vert_curves_begin, hori_curves_begin);
    let curves_length = array(vert_curves_length, hori_curves_length);
    let r2 = radius * radius;

    for (var j = 0u; j < 2; j++) {
        for (var i = 0u; i < curves_length[j]; i++) {
            let curve_begin = glyph_band_segment_curves[curves_begin[j] + i];

            let p0 = glyph_points[curve_begin] - em_uv;
            let p1 = glyph_points[curve_begin + 1u] - em_uv;
            let p2 = glyph_points[curve_begin + 2u] - em_uv;

            if (dot(p0, p0) < r2) {
                pkind |= PKIND_P0;
                dist = min(dist, length(p0));
            }
            if (dot(p1, p1) < r2) {
                pkind |= PKIND_P1;
                dist = min(dist, length(p1));
            }
            if (dot(p2, p2) < r2) {
                pkind |= PKIND_P2;
                dist = min(dist, length(p2));
            }
        }
    }

    return PKindRes(pkind, dist);
}

fn control_points_overlay(
    vert_curves_begin: u32,
    vert_curves_length: u32, 
    hori_curves_begin: u32, 
    hori_curves_length: u32,
    fw: vec2<f32>,
    em_uv: vec2<f32>,
) -> vec4<f32> {
    let em_per_unit = min(fw.x, fw.y);
    let radius = 2.5;
    let aa_radius = 0.5;

    let pkind_res = get_control_point_kind(
        vert_curves_begin,
        vert_curves_length,
        hori_curves_begin,
        hori_curves_length,
        em_uv,
        (radius + aa_radius) * em_per_unit,
    );
    let dist = pkind_res.dist / em_per_unit;

    let ol_alpha = 
        clamp((radius - dist + aa_radius) / aa_radius, 0.0, 1.0);

    switch pkind_res.pkind {
        case PKIND_NONE: {}

        case PKIND_P0, PKIND_P2: {
            return vec4<f32>(1.0, 1.0, 0.0, ol_alpha);
        }
        case PKIND_P1: {
            return vec4<f32>(0.0, 1.0, 0.0, ol_alpha);
        }
        default: {
            return vec4<f32>(1.0, 0.0, 1.0, ol_alpha);
        }
    }
    return vec4<f32>(0.0);
}


fn blend(bg: vec4<f32>, fg: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(
        bg.xyz * (1.0 - fg.w) + fg.xyz * fg.w,
        bg.w * (1.0 - fg.w) + fg.w,
    );
}

@fragment fn frag_main(vert: VertexOut) -> @location(0) vec4<f32> {
    // let segment_begin = u32(abs(vert.segment_begin));
    let em_uv = vert.em_uv;

    let fw = fwidth(em_uv);
    let inverse_sample_diameter = 1.0 / (1.4*fw);

    let vert_curves_begin = vert.vert_curves_begin;
    let vert_curves_length = vert.vh_curves_lengths >> 16;
    let hori_curves_begin = vert.hori_curves_begin;
    let hori_curves_length = vert.vh_curves_lengths & 0xffff;

    var alpha: f32 = 0.0;

    alpha += compute_corverage( 
        false,
        hori_curves_begin,
        hori_curves_length,
        inverse_sample_diameter.x,
        em_uv,
    );
    alpha += compute_corverage( 
        true,
        vert_curves_begin,
        vert_curves_length,
        inverse_sample_diameter.y,
        em_uv,
    );

    alpha = clamp(alpha * 0.5, 0.0, 1.0);

    var out = vec4<f32>(0.0, 0.0, 0.0, alpha);

    if (show_em_uv) {
        out.x = em_uv.x;
        out.y = em_uv.y;
    }

    if (show_control_points) {
        let overlay = control_points_overlay(
            vert_curves_begin,
            vert_curves_length,
            hori_curves_begin,
            hori_curves_length,
            fw,
            em_uv,
        );
        out = blend(out, overlay);
    }

    if (show_segments) {
        let seg = vec4<f32>(rand_color_2d(vec2<f32>(
            f32(vert.hori_curves_begin),
            f32(vert.vert_curves_begin),
        )), 0.5);
        out = blend(seg, out);
    }

    return out;

    // let xy_even = floor(vert.uv * 6.0) % 2.0;
    // return vec4<f32>(1.0, 0.0, 1.0, abs(xy_even.x - xy_even.y));
}
