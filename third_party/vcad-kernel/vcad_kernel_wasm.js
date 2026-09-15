/* @ts-self-types="./axis_kernel_wasm.d.ts" */

/**
 * A 3D solid geometry object.
 *
 * Create solids from primitives, combine with boolean operations,
 * transform, and extract triangle meshes for rendering.
 */
export class Solid {
    static __wrap(ptr) {
        ptr = ptr >>> 0;
        const obj = Object.create(Solid.prototype);
        obj.__wbg_ptr = ptr;
        SolidFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        SolidFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_solid_free(ptr, 0);
    }
    /**
     * Return mesh boundary edges as a flat float array
     * `[x0, y0, z0, x1, y1, z1, ...]` with each pair of 3-component
     * positions defining one edge segment. Used by the viewport's
     * "show boundary edges" overlay to surface tessellation holes.
     *
     * Closed, manifold meshes return an empty array; each entry means
     * there's a hole in the mesh.
     * @param {number | null} [segments]
     * @returns {Float32Array}
     */
    boundaryEdges(segments) {
        const ret = wasm.solid_boundaryEdges(this.__wbg_ptr, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        var v1 = getArrayF32FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Get the bounding box as [minX, minY, minZ, maxX, maxY, maxZ].
     * @returns {Float64Array}
     */
    boundingBox() {
        const ret = wasm.solid_boundingBox(this.__wbg_ptr);
        var v1 = getArrayF64FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 8, 8);
        return v1;
    }
    /**
     * Check if the solid can be exported to STEP format.
     *
     * Returns `true` if the solid has B-rep data available for STEP export.
     * Returns `false` for mesh-only or empty solids.
     * @returns {boolean}
     */
    canExportStep() {
        const ret = wasm.solid_canExportStep(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * Get the center of mass as [x, y, z].
     * @returns {Float64Array}
     */
    centerOfMass() {
        const ret = wasm.solid_centerOfMass(this.__wbg_ptr);
        var v1 = getArrayF64FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 8, 8);
        return v1;
    }
    /**
     * Chamfer all edges of the solid by the given distance.
     * @param {number} distance
     * @returns {Solid}
     */
    chamfer(distance) {
        const ret = wasm.solid_chamfer(this.__wbg_ptr, distance);
        return Solid.__wrap(ret);
    }
    /**
     * Create a circular pattern of the solid around an axis.
     *
     * # Arguments
     *
     * * `axis_origin_x/y/z` - A point on the rotation axis
     * * `axis_dir_x/y/z` - Direction of the rotation axis
     * * `count` - Number of copies (including original)
     * * `angle_deg` - Total angle span in degrees
     * @param {number} axis_origin_x
     * @param {number} axis_origin_y
     * @param {number} axis_origin_z
     * @param {number} axis_dir_x
     * @param {number} axis_dir_y
     * @param {number} axis_dir_z
     * @param {number} count
     * @param {number} angle_deg
     * @returns {Solid}
     */
    circularPattern(axis_origin_x, axis_origin_y, axis_origin_z, axis_dir_x, axis_dir_y, axis_dir_z, count, angle_deg) {
        const ret = wasm.solid_circularPattern(this.__wbg_ptr, axis_origin_x, axis_origin_y, axis_origin_z, axis_dir_x, axis_dir_y, axis_dir_z, count, angle_deg);
        return Solid.__wrap(ret);
    }
    /**
     * Minimum signed distance to another solid in mm (see `WasmClearance`):
     * positive separation, negative penetration depth on intersection.
     * @param {Solid} other
     * @returns {any}
     */
    clearance(other) {
        _assertClass(other, Solid);
        const ret = wasm.solid_clearance(this.__wbg_ptr, other.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return takeFromExternrefTable0(ret[0]);
    }
    /**
     * Create a cone/frustum along Z axis.
     * @param {number} radius_bottom
     * @param {number} radius_top
     * @param {number} height
     * @param {number | null} [segments]
     * @returns {Solid}
     */
    static cone(radius_bottom, radius_top, height, segments) {
        const ret = wasm.solid_cone(radius_bottom, radius_top, height, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return Solid.__wrap(ret);
    }
    /**
     * Create a box with corner at origin and dimensions (sx, sy, sz).
     * @param {number} sx
     * @param {number} sy
     * @param {number} sz
     * @returns {Solid}
     */
    static cube(sx, sy, sz) {
        const ret = wasm.solid_cube(sx, sy, sz);
        return Solid.__wrap(ret);
    }
    /**
     * Create a cylinder along Z axis with given radius and height.
     * @param {number} radius
     * @param {number} height
     * @param {number | null} [segments]
     * @returns {Solid}
     */
    static cylinder(radius, height, segments) {
        const ret = wasm.solid_cylinder(radius, height, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return Solid.__wrap(ret);
    }
    /**
     * Boolean difference (self − other).
     *
     * Returns a JS error (instead of trapping the WASM instance) when the
     * kernel reports a boolean failure.
     * @param {Solid} other
     * @returns {Solid}
     */
    difference(other) {
        _assertClass(other, Solid);
        const ret = wasm.solid_difference(this.__wbg_ptr, other.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Per-edge blend on query-selected edges with a keyed profile.
     *
     * `spec_json` is a JSON object `{ "edges": EdgeQuery, "profile":
     * BlendProfile }` using the IR types (serde-tagged with `type`).
     * shape 0 = chamfer, 1 = fillet; size = chamfer leg / fillet radius.
     * @param {string} spec_json
     * @returns {Solid}
     */
    edgeBlend(spec_json) {
        const ptr0 = passStringToWasm0(spec_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.solid_edgeBlend(this.__wbg_ptr, ptr0, len0);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Create an empty solid.
     * @returns {Solid}
     */
    static empty() {
        const ret = wasm.solid_empty();
        return Solid.__wrap(ret);
    }
    /**
     * Create a solid by extruding a 2D sketch profile.
     *
     * Takes a sketch profile and extrusion direction as JS objects.
     * @param {string} profile_json
     * @param {Float64Array} direction
     * @returns {Solid}
     */
    static extrude(profile_json, direction) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(direction, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.solid_extrude(ptr0, len0, ptr1, len1);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Create a solid by extruding a 2D sketch profile with twist and/or scale.
     *
     * Takes a sketch profile, extrusion direction, twist angle (radians),
     * and scale factor at the end (1.0 = no taper).
     * @param {string} profile_json
     * @param {Float64Array} direction
     * @param {number} twist_angle
     * @param {number} scale_end
     * @returns {Solid}
     */
    static extrudeWithOptions(profile_json, direction, twist_angle, scale_end) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(direction, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.solid_extrudeWithOptions(ptr0, len0, ptr1, len1, twist_angle, scale_end);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Fillet all edges of the solid with the given radius.
     * @param {number} radius
     * @returns {Solid}
     */
    fillet(radius) {
        const ret = wasm.solid_fillet(this.__wbg_ptr, radius);
        return Solid.__wrap(ret);
    }
    /**
     * Reopen one retained B-rep body from a STEP buffer.
     * @param {Uint8Array} data
     * @param {number} body_index
     * @returns {Solid}
     */
    static fromStepBuffer(data, body_index) {
        const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.solid_fromStepBuffer(ptr0, len0, body_index);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Get the triangle mesh representation.
     *
     * Returns a JS object with `positions` (Float32Array) and `indices` (Uint32Array).
     *
     * Runs the tessellator output through
     * [`vcad_kernel_tessellate::render_bake`] so the emitted mesh carries
     * angle-based creased vertex normals. Every downstream renderer —
     * three.js today, wgpu / STL / GLB / ray tracer later — consumes this
     * same attribute layout without recomputing anything.
     * @param {number | null} [segments]
     * @returns {any}
     */
    getMesh(segments) {
        const ret = wasm.solid_getMesh(this.__wbg_ptr, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return ret;
    }
    /**
     * Generate a horizontal section view at a given Z height.
     *
     * Convenience method that creates a horizontal section plane.
     * @param {number} z
     * @param {number | null} [hatch_spacing]
     * @param {number | null} [hatch_angle]
     * @param {number | null} [segments]
     * @returns {any}
     */
    horizontalSection(z, hatch_spacing, hatch_angle, segments) {
        const ret = wasm.solid_horizontalSection(this.__wbg_ptr, z, !isLikeNone(hatch_spacing), isLikeNone(hatch_spacing) ? 0 : hatch_spacing, !isLikeNone(hatch_angle), isLikeNone(hatch_angle) ? 0 : hatch_angle, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return ret;
    }
    /**
     * Boolean intersection (self ∩ other).
     *
     * Returns a JS error (instead of trapping the WASM instance) when the
     * kernel reports a boolean failure.
     * @param {Solid} other
     * @returns {Solid}
     */
    intersection(other) {
        _assertClass(other, Solid);
        const ret = wasm.solid_intersection(this.__wbg_ptr, other.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Export to STEP and consume the wrapper in one operation.
     * @returns {Uint8Array}
     */
    intoStepBuffer() {
        const ptr = this.__destroy_into_raw();
        const ret = wasm.solid_intoStepBuffer(ptr);
        if (ret[3]) {
            throw takeFromExternrefTable0(ret[2]);
        }
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Check if the solid is empty (has no geometry).
     * @returns {boolean}
     */
    isEmpty() {
        const ret = wasm.solid_isEmpty(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * Create a linear pattern of the solid along a direction.
     *
     * # Arguments
     *
     * * `dir_x`, `dir_y`, `dir_z` - Direction vector
     * * `count` - Number of copies (including original)
     * * `spacing` - Distance between copies
     * @param {number} dir_x
     * @param {number} dir_y
     * @param {number} dir_z
     * @param {number} count
     * @param {number} spacing
     * @returns {Solid}
     */
    linearPattern(dir_x, dir_y, dir_z, count, spacing) {
        const ret = wasm.solid_linearPattern(this.__wbg_ptr, dir_x, dir_y, dir_z, count, spacing);
        return Solid.__wrap(ret);
    }
    /**
     * Create a solid by lofting between multiple profiles.
     *
     * Takes an array of sketch profiles (minimum 2).
     * @param {string} profiles_json
     * @param {boolean | null} [closed]
     * @returns {Solid}
     */
    static loft(profiles_json, closed) {
        const ptr0 = passStringToWasm0(profiles_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.solid_loft(ptr0, len0, isLikeNone(closed) ? 0xFFFFFF : closed ? 1 : 0);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Mirror the solid across a plane through `(origin_x, origin_y, origin_z)`
     * with the given plane normal. Triangle / face winding is automatically
     * reversed to preserve outward normals.
     * @param {number} origin_x
     * @param {number} origin_y
     * @param {number} origin_z
     * @param {number} normal_x
     * @param {number} normal_y
     * @param {number} normal_z
     * @returns {Solid}
     */
    mirror(origin_x, origin_y, origin_z, normal_x, normal_y, normal_z) {
        const ret = wasm.solid_mirror(this.__wbg_ptr, origin_x, origin_y, origin_z, normal_x, normal_y, normal_z);
        return Solid.__wrap(ret);
    }
    /**
     * Get the number of triangles in the tessellated mesh.
     * @returns {number}
     */
    numTriangles() {
        const ret = wasm.solid_numTriangles(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * Create a regular n-gonal right prism centered on Z.
     * @param {number} sides
     * @param {number} radius
     * @param {number} height
     * @returns {Solid}
     */
    static prism(sides, radius, height) {
        const ret = wasm.solid_prism(sides, radius, height);
        return Solid.__wrap(ret);
    }
    /**
     * Project the solid to a 2D view for technical drawing.
     *
     * # Arguments
     * * `view_direction` - View direction: "front", "back", "top", "bottom", "left", "right", or "isometric"
     * * `segments` - Number of segments for tessellation (optional, default 32)
     *
     * # Returns
     * A JS object containing the projected view with edges and bounds.
     * @param {string} view_direction
     * @param {number | null} [segments]
     * @returns {any}
     */
    projectView(view_direction, segments) {
        const ptr0 = passStringToWasm0(view_direction, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.solid_projectView(this.__wbg_ptr, ptr0, len0, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return ret;
    }
    /**
     * Create a solid by revolving a 2D sketch profile around an axis.
     *
     * Takes a sketch profile, axis origin, axis direction, and angle in degrees.
     * @param {string} profile_json
     * @param {Float64Array} axis_origin
     * @param {Float64Array} axis_dir
     * @param {number} angle_deg
     * @returns {Solid}
     */
    static revolve(profile_json, axis_origin, axis_dir, angle_deg) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(axis_origin, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArrayF64ToWasm0(axis_dir, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        const ret = wasm.solid_revolve(ptr0, len0, ptr1, len1, ptr2, len2, angle_deg);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Rotate the solid by angles in degrees around X, Y, Z axes.
     * @param {number} x_deg
     * @param {number} y_deg
     * @param {number} z_deg
     * @returns {Solid}
     */
    rotate(x_deg, y_deg, z_deg) {
        const ret = wasm.solid_rotate(this.__wbg_ptr, x_deg, y_deg, z_deg);
        return Solid.__wrap(ret);
    }
    /**
     * Run DFM directly on this solid's BRep.
     *
     * Returns the report JSON; if the solid is mesh-only (e.g. after
     * a boolean — see issue #186), the report has an empty `issues`
     * array and a note in `rule_pack_name`.
     *
     * `root_node_id` (when > 0) attributes every face in the BRep to
     * that IR node — the v1 coarse provenance heuristic. Pass 0 to
     * skip provenance entirely; emitted issues will then carry
     * `origin_op: null` and `dfm_apply_fix` will only be able to act
     * on rules whose fix kind is `manual`.
     * @param {string} process
     * @param {string} rule_pack_toml
     * @param {bigint} root_node_id
     * @returns {string}
     */
    runDfm(process, rule_pack_toml, root_node_id) {
        let deferred4_0;
        let deferred4_1;
        try {
            const ptr0 = passStringToWasm0(process, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len0 = WASM_VECTOR_LEN;
            const ptr1 = passStringToWasm0(rule_pack_toml, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            const ret = wasm.solid_runDfm(this.__wbg_ptr, ptr0, len0, ptr1, len1, root_node_id);
            var ptr3 = ret[0];
            var len3 = ret[1];
            if (ret[3]) {
                ptr3 = 0; len3 = 0;
                throw takeFromExternrefTable0(ret[2]);
            }
            deferred4_0 = ptr3;
            deferred4_1 = len3;
            return getStringFromWasm0(ptr3, len3);
        } finally {
            wasm.__wbindgen_free(deferred4_0, deferred4_1, 1);
        }
    }
    /**
     * Scale the solid by (x, y, z).
     * @param {number} x
     * @param {number} y
     * @param {number} z
     * @returns {Solid}
     */
    scale(x, y, z) {
        const ret = wasm.solid_scale(this.__wbg_ptr, x, y, z);
        return Solid.__wrap(ret);
    }
    /**
     * Generate a section view by cutting the solid with a plane.
     *
     * # Arguments
     * * `plane_json` - JSON string with plane definition: `{"origin": [x,y,z], "normal": [x,y,z], "up": [x,y,z]}`
     * * `hatch_json` - Optional JSON string with hatch pattern: `{"spacing": f64, "angle": f64}`
     * * `segments` - Number of segments for tessellation (optional, default 32)
     *
     * # Returns
     * A JS object containing the section view with curves, hatch lines, and bounds.
     * @param {string} plane_json
     * @param {string | null} [hatch_json]
     * @param {number | null} [segments]
     * @returns {any}
     */
    sectionView(plane_json, hatch_json, segments) {
        const ptr0 = passStringToWasm0(plane_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        var ptr1 = isLikeNone(hatch_json) ? 0 : passStringToWasm0(hatch_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len1 = WASM_VECTOR_LEN;
        const ret = wasm.solid_sectionView(this.__wbg_ptr, ptr0, len0, ptr1, len1, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return ret;
    }
    /**
     * Shell (hollow) the solid by offsetting all faces inward.
     * @param {number} thickness
     * @returns {Solid}
     */
    shell(thickness) {
        const ret = wasm.solid_shell(this.__wbg_ptr, thickness);
        return Solid.__wrap(ret);
    }
    /**
     * Create a sphere centered at origin with given radius.
     * @param {number} radius
     * @param {number | null} [segments]
     * @returns {Solid}
     */
    static sphere(radius, segments) {
        const ret = wasm.solid_sphere(radius, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return Solid.__wrap(ret);
    }
    /**
     * Compute the surface area of the solid.
     * @returns {number}
     */
    surfaceArea() {
        const ret = wasm.solid_surfaceArea(this.__wbg_ptr);
        return ret;
    }
    /**
     * Sweep along a JSON line/arc path. The vendored kernel samples the
     * supplied path into a deterministic polyline before creating the B-rep.
     * @param {string} profile_json
     * @param {string} segments_json
     * @param {number | null | undefined} twist_angle
     * @param {number | null | undefined} scale_start
     * @param {number | null | undefined} scale_end
     * @param {number | null | undefined} path_segments
     * @param {number | null | undefined} arc_segments
     * @param {number | null | undefined} orientation
     * @param {string} _scale_stations_json
     * @param {string} _profile_stations_json
     * @param {number | null | undefined} _frame_mode
     * @param {Float64Array} _up_direction
     * @param {Float64Array} _guide_points
     * @param {number | null} [_continuity_mode]
     * @param {number | null} [_tangent_tolerance_degrees]
     * @returns {Solid}
     */
    static sweepComposite(profile_json, segments_json, twist_angle, scale_start, scale_end, path_segments, arc_segments, orientation, _scale_stations_json, _profile_stations_json, _frame_mode, _up_direction, _guide_points, _continuity_mode, _tangent_tolerance_degrees) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(segments_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(_scale_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(_profile_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        const ptr4 = passArrayF64ToWasm0(_up_direction, wasm.__wbindgen_malloc);
        const len4 = WASM_VECTOR_LEN;
        const ptr5 = passArrayF64ToWasm0(_guide_points, wasm.__wbindgen_malloc);
        const len5 = WASM_VECTOR_LEN;
        const ret = wasm.solid_sweepComposite(ptr0, len0, ptr1, len1, !isLikeNone(twist_angle), isLikeNone(twist_angle) ? 0 : twist_angle, !isLikeNone(scale_start), isLikeNone(scale_start) ? 0 : scale_start, !isLikeNone(scale_end), isLikeNone(scale_end) ? 0 : scale_end, isLikeNone(path_segments) ? 0x100000001 : (path_segments) >>> 0, isLikeNone(arc_segments) ? 0x100000001 : (arc_segments) >>> 0, !isLikeNone(orientation), isLikeNone(orientation) ? 0 : orientation, ptr2, len2, ptr3, len3, isLikeNone(_frame_mode) ? 0x100000001 : (_frame_mode) >>> 0, ptr4, len4, ptr5, len5, isLikeNone(_continuity_mode) ? 0x100000001 : (_continuity_mode) >>> 0, !isLikeNone(_tangent_tolerance_degrees), isLikeNone(_tangent_tolerance_degrees) ? 0 : _tangent_tolerance_degrees);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Create a solid by sweeping a profile along a helix path.
     *
     * Takes a sketch profile and helix parameters.
     * @param {string} profile_json
     * @param {number} radius
     * @param {number} pitch
     * @param {number} height
     * @param {number} turns
     * @param {number | null} [twist_angle]
     * @param {number | null} [scale_start]
     * @param {number | null} [scale_end]
     * @param {number | null} [path_segments]
     * @param {number | null} [arc_segments]
     * @param {number | null} [orientation]
     * @returns {Solid}
     */
    static sweepHelix(profile_json, radius, pitch, height, turns, twist_angle, scale_start, scale_end, path_segments, arc_segments, orientation) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.solid_sweepHelix(ptr0, len0, radius, pitch, height, turns, !isLikeNone(twist_angle), isLikeNone(twist_angle) ? 0 : twist_angle, !isLikeNone(scale_start), isLikeNone(scale_start) ? 0 : scale_start, !isLikeNone(scale_end), isLikeNone(scale_end) ? 0 : scale_end, isLikeNone(path_segments) ? 0x100000001 : (path_segments) >>> 0, isLikeNone(arc_segments) ? 0x100000001 : (arc_segments) >>> 0, !isLikeNone(orientation), isLikeNone(orientation) ? 0 : orientation);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Create a solid by sweeping a profile along a line path.
     *
     * Takes a sketch profile and path endpoints.
     * @param {string} profile_json
     * @param {Float64Array} start
     * @param {Float64Array} end
     * @param {number | null | undefined} twist_angle
     * @param {number | null | undefined} scale_start
     * @param {number | null | undefined} scale_end
     * @param {number | null | undefined} orientation
     * @param {string | null | undefined} scale_stations_json
     * @param {string | null | undefined} profile_stations_json
     * @param {number | null | undefined} _frame_mode
     * @param {Float64Array} _up_direction
     * @param {Float64Array} _guide_points
     * @returns {Solid}
     */
    static sweepLine(profile_json, start, end, twist_angle, scale_start, scale_end, orientation, scale_stations_json, profile_stations_json, _frame_mode, _up_direction, _guide_points) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(start, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArrayF64ToWasm0(end, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        var ptr3 = isLikeNone(scale_stations_json) ? 0 : passStringToWasm0(scale_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len3 = WASM_VECTOR_LEN;
        var ptr4 = isLikeNone(profile_stations_json) ? 0 : passStringToWasm0(profile_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len4 = WASM_VECTOR_LEN;
        const ptr5 = passArrayF64ToWasm0(_up_direction, wasm.__wbindgen_malloc);
        const len5 = WASM_VECTOR_LEN;
        const ptr6 = passArrayF64ToWasm0(_guide_points, wasm.__wbindgen_malloc);
        const len6 = WASM_VECTOR_LEN;
        const ret = wasm.solid_sweepLine(ptr0, len0, ptr1, len1, ptr2, len2, !isLikeNone(twist_angle), isLikeNone(twist_angle) ? 0 : twist_angle, !isLikeNone(scale_start), isLikeNone(scale_start) ? 0 : scale_start, !isLikeNone(scale_end), isLikeNone(scale_end) ? 0 : scale_end, !isLikeNone(orientation), isLikeNone(orientation) ? 0 : orientation, ptr3, len3, ptr4, len4, isLikeNone(_frame_mode) ? 0x100000001 : (_frame_mode) >>> 0, ptr5, len5, ptr6, len6);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Sweep along a spline control polygon using deterministic interpolation.
     * @param {string} profile_json
     * @param {Float64Array} points
     * @param {number | null | undefined} twist_angle
     * @param {number | null | undefined} scale_start
     * @param {number | null | undefined} scale_end
     * @param {number | null | undefined} path_segments
     * @param {number | null | undefined} arc_segments
     * @param {number | null | undefined} orientation
     * @param {string} _scale_stations_json
     * @param {string} _profile_stations_json
     * @param {number | null | undefined} _frame_mode
     * @param {Float64Array} _up_direction
     * @param {Float64Array} _guide_points
     * @param {Float64Array} start_tangent
     * @param {Float64Array} end_tangent
     * @returns {Solid}
     */
    static sweepSpline(profile_json, points, twist_angle, scale_start, scale_end, path_segments, arc_segments, orientation, _scale_stations_json, _profile_stations_json, _frame_mode, _up_direction, _guide_points, start_tangent, end_tangent) {
        const ptr0 = passStringToWasm0(profile_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(points, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passStringToWasm0(_scale_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passStringToWasm0(_profile_stations_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len3 = WASM_VECTOR_LEN;
        const ptr4 = passArrayF64ToWasm0(_up_direction, wasm.__wbindgen_malloc);
        const len4 = WASM_VECTOR_LEN;
        const ptr5 = passArrayF64ToWasm0(_guide_points, wasm.__wbindgen_malloc);
        const len5 = WASM_VECTOR_LEN;
        const ptr6 = passArrayF64ToWasm0(start_tangent, wasm.__wbindgen_malloc);
        const len6 = WASM_VECTOR_LEN;
        const ptr7 = passArrayF64ToWasm0(end_tangent, wasm.__wbindgen_malloc);
        const len7 = WASM_VECTOR_LEN;
        const ret = wasm.solid_sweepSpline(ptr0, len0, ptr1, len1, !isLikeNone(twist_angle), isLikeNone(twist_angle) ? 0 : twist_angle, !isLikeNone(scale_start), isLikeNone(scale_start) ? 0 : scale_start, !isLikeNone(scale_end), isLikeNone(scale_end) ? 0 : scale_end, isLikeNone(path_segments) ? 0x100000001 : (path_segments) >>> 0, isLikeNone(arc_segments) ? 0x100000001 : (arc_segments) >>> 0, !isLikeNone(orientation), isLikeNone(orientation) ? 0 : orientation, ptr2, len2, ptr3, len3, isLikeNone(_frame_mode) ? 0x100000001 : (_frame_mode) >>> 0, ptr4, len4, ptr5, len5, ptr6, len6, ptr7, len7);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Create a solid by extruding text as 2D profiles.
     *
     * Converts text to sketch profiles and extrudes them. Each character glyph
     * becomes a separate profile, and holes (like in 'O') are subtracted.
     *
     * # Arguments
     *
     * * `text` - The text string to convert
     * * `origin` - Origin point [x, y, z]
     * * `x_dir` - X direction vector [x, y, z]
     * * `y_dir` - Y direction vector [x, y, z]
     * * `direction` - Extrusion direction [x, y, z] (magnitude = extrusion depth)
     * * `height` - Text height in mm
     * * `font` - Font name (currently only "sans-serif" supported)
     * * `alignment` - Text alignment: "left", "center", or "right"
     * * `letter_spacing` - Letter spacing multiplier (1.0 = normal)
     * * `line_spacing` - Line spacing multiplier (1.0 = normal)
     * @param {string} text
     * @param {Float64Array} origin
     * @param {Float64Array} x_dir
     * @param {Float64Array} y_dir
     * @param {Float64Array} direction
     * @param {number} height
     * @param {string | null} [font]
     * @param {string | null} [alignment]
     * @param {number | null} [letter_spacing]
     * @param {number | null} [line_spacing]
     * @returns {Solid}
     */
    static textExtrude(text, origin, x_dir, y_dir, direction, height, font, alignment, letter_spacing, line_spacing) {
        const ptr0 = passStringToWasm0(text, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArrayF64ToWasm0(origin, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ptr2 = passArrayF64ToWasm0(x_dir, wasm.__wbindgen_malloc);
        const len2 = WASM_VECTOR_LEN;
        const ptr3 = passArrayF64ToWasm0(y_dir, wasm.__wbindgen_malloc);
        const len3 = WASM_VECTOR_LEN;
        const ptr4 = passArrayF64ToWasm0(direction, wasm.__wbindgen_malloc);
        const len4 = WASM_VECTOR_LEN;
        var ptr5 = isLikeNone(font) ? 0 : passStringToWasm0(font, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len5 = WASM_VECTOR_LEN;
        var ptr6 = isLikeNone(alignment) ? 0 : passStringToWasm0(alignment, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        var len6 = WASM_VECTOR_LEN;
        const ret = wasm.solid_textExtrude(ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3, ptr4, len4, height, ptr5, len5, ptr6, len6, !isLikeNone(letter_spacing), isLikeNone(letter_spacing) ? 0 : letter_spacing, !isLikeNone(line_spacing), isLikeNone(line_spacing) ? 0 : line_spacing);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Export the solid to STEP format.
     *
     * # Returns
     * A byte buffer containing the STEP file data.
     *
     * # Errors
     * Returns an error if the solid has no B-rep data (e.g., mesh-only after certain operations).
     * @returns {Uint8Array}
     */
    toStepBuffer() {
        const ret = wasm.solid_toStepBuffer(this.__wbg_ptr);
        if (ret[3]) {
            throw takeFromExternrefTable0(ret[2]);
        }
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Create a torus centered at origin with axis along Z.
     * @param {number} major_radius
     * @param {number} minor_radius
     * @param {number | null} [segments]
     * @returns {Solid}
     */
    static torus(major_radius, minor_radius, segments) {
        const ret = wasm.solid_torus(major_radius, minor_radius, isLikeNone(segments) ? 0x100000001 : (segments) >>> 0);
        return Solid.__wrap(ret);
    }
    /**
     * Translate the solid by (x, y, z).
     * @param {number} x
     * @param {number} y
     * @param {number} z
     * @returns {Solid}
     */
    translate(x, y, z) {
        const ret = wasm.solid_translate(this.__wbg_ptr, x, y, z);
        return Solid.__wrap(ret);
    }
    /**
     * Boolean union (self ∪ other).
     *
     * Returns a JS error (instead of trapping the WASM instance) when the
     * kernel reports a boolean failure.
     * @param {Solid} other
     * @returns {Solid}
     */
    union(other) {
        _assertClass(other, Solid);
        const ret = wasm.solid_union(this.__wbg_ptr, other.__wbg_ptr);
        if (ret[2]) {
            throw takeFromExternrefTable0(ret[1]);
        }
        return Solid.__wrap(ret[0]);
    }
    /**
     * Compute the volume of the solid.
     * @returns {number}
     */
    volume() {
        const ret = wasm.solid_volume(this.__wbg_ptr);
        return ret;
    }
    /**
     * Create a right-triangular-prism wedge with corner at origin.
     * @param {number} sx
     * @param {number} sy
     * @param {number} sz
     * @returns {Solid}
     */
    static wedge(sx, sy, sz) {
        const ret = wasm.solid_wedge(sx, sy, sz);
        return Solid.__wrap(ret);
    }
}
if (Symbol.dispose) Solid.prototype[Symbol.dispose] = Solid.prototype.free;

/**
 * Static structural analysis of a box solid.
 *
 * `spec_json` is a serialized `vcad_kernel_topopt::AnalysisSpec` (loads,
 * supports, resolution, youngs_modulus_mpa, poisson).
 * @param {string} spec_json
 * @param {number} min_x
 * @param {number} min_y
 * @param {number} min_z
 * @param {number} max_x
 * @param {number} max_y
 * @param {number} max_z
 * @returns {any}
 */
export function analyzeStaticsBox(spec_json, min_x, min_y, min_z, max_x, max_y, max_z) {
    const ptr0 = passStringToWasm0(spec_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.analyzeStaticsBox(ptr0, len0, min_x, min_y, min_z, max_x, max_y, max_z);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * Static structural analysis of an existing (closed) evaluated mesh: the
 * mesh interior is voxelized and solved under the given loads/supports.
 * @param {string} spec_json
 * @param {Float32Array} positions
 * @param {Uint32Array} indices
 * @returns {any}
 */
export function analyzeStaticsMesh(spec_json, positions, indices) {
    const ptr0 = passStringToWasm0(spec_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ptr1 = passArrayF32ToWasm0(positions, wasm.__wbindgen_malloc);
    const len1 = WASM_VECTOR_LEN;
    const ptr2 = passArray32ToWasm0(indices, wasm.__wbindgen_malloc);
    const len2 = WASM_VECTOR_LEN;
    const ret = wasm.analyzeStaticsMesh(ptr0, len0, ptr1, len1, ptr2, len2);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * @param {Uint8Array} data
 * @returns {any}
 */
export function importStepBuffer(data) {
    const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.importStepBuffer(ptr0, len0);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

export function init() {
    wasm.init();
}

/**
 * @param {Uint8Array} data
 * @returns {string}
 */
export function inspectStepBuffer(data) {
    let deferred3_0;
    let deferred3_1;
    try {
        const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.inspectStepBuffer(ptr0, len0);
        var ptr2 = ret[0];
        var len2 = ret[1];
        if (ret[3]) {
            ptr2 = 0; len2 = 0;
            throw takeFromExternrefTable0(ret[2]);
        }
        deferred3_0 = ptr2;
        deferred3_1 = len2;
        return getStringFromWasm0(ptr2, len2);
    } finally {
        wasm.__wbindgen_free(deferred3_0, deferred3_1, 1);
    }
}

/**
 * Mesh-to-mesh clearance over raw evaluated-mesh buffers (see
 * `WasmClearance`). Operates on already-placed geometry, so callers can
 * measure between any two evaluated parts (or merged part groups) without
 * re-building solids.
 * @param {Float32Array} positions_a
 * @param {Uint32Array} indices_a
 * @param {Float32Array} positions_b
 * @param {Uint32Array} indices_b
 * @returns {any}
 */
export function mesh_clearance(positions_a, indices_a, positions_b, indices_b) {
    const ptr0 = passArrayF32ToWasm0(positions_a, wasm.__wbindgen_malloc);
    const len0 = WASM_VECTOR_LEN;
    const ptr1 = passArray32ToWasm0(indices_a, wasm.__wbindgen_malloc);
    const len1 = WASM_VECTOR_LEN;
    const ptr2 = passArrayF32ToWasm0(positions_b, wasm.__wbindgen_malloc);
    const len2 = WASM_VECTOR_LEN;
    const ptr3 = passArray32ToWasm0(indices_b, wasm.__wbindgen_malloc);
    const len3 = WASM_VECTOR_LEN;
    const ret = wasm.mesh_clearance(ptr0, len0, ptr1, len1, ptr2, len2, ptr3, len3);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * SIMP topology optimization over a box design domain.
 *
 * `spec_json` is a serialized `vcad_kernel_topopt::TopoOptSpec` (loads,
 * supports, volume fraction, resolution, ...). Returns a
 * `WasmTopoOptResult`.
 * @param {string} spec_json
 * @param {number} min_x
 * @param {number} min_y
 * @param {number} min_z
 * @param {number} max_x
 * @param {number} max_y
 * @param {number} max_z
 * @returns {any}
 */
export function topologyOptimizeBox(spec_json, min_x, min_y, min_z, max_x, max_y, max_z) {
    const ptr0 = passStringToWasm0(spec_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ret = wasm.topologyOptimizeBox(ptr0, len0, min_x, min_y, min_z, max_x, max_y, max_z);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

/**
 * SIMP topology optimization inside an existing (closed) evaluated mesh:
 * the mesh's interior becomes the design domain, so material only appears
 * where the original part had volume.
 * @param {string} spec_json
 * @param {Float32Array} positions
 * @param {Uint32Array} indices
 * @returns {any}
 */
export function topologyOptimizeMesh(spec_json, positions, indices) {
    const ptr0 = passStringToWasm0(spec_json, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
    const len0 = WASM_VECTOR_LEN;
    const ptr1 = passArrayF32ToWasm0(positions, wasm.__wbindgen_malloc);
    const len1 = WASM_VECTOR_LEN;
    const ptr2 = passArray32ToWasm0(indices, wasm.__wbindgen_malloc);
    const len2 = WASM_VECTOR_LEN;
    const ret = wasm.topologyOptimizeMesh(ptr0, len0, ptr1, len1, ptr2, len2);
    if (ret[2]) {
        throw takeFromExternrefTable0(ret[1]);
    }
    return takeFromExternrefTable0(ret[0]);
}

function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg_Error_8c4e43fe74559d73: function(arg0, arg1) {
            const ret = Error(getStringFromWasm0(arg0, arg1));
            return ret;
        },
        __wbg_String_8f0eb39a4a4c2f66: function(arg0, arg1) {
            const ret = String(arg1);
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg___wbindgen_throw_be289d5034ed271b: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbg_error_7534b8e9a36f1ab4: function(arg0, arg1) {
            let deferred0_0;
            let deferred0_1;
            try {
                deferred0_0 = arg0;
                deferred0_1 = arg1;
                console.error(getStringFromWasm0(arg0, arg1));
            } finally {
                wasm.__wbindgen_free(deferred0_0, deferred0_1, 1);
            }
        },
        __wbg_error_9a7fe3f932034cde: function(arg0) {
            console.error(arg0);
        },
        __wbg_log_6b5ca2e6124b2808: function(arg0) {
            console.log(arg0);
        },
        __wbg_new_361308b2356cecd0: function() {
            const ret = new Object();
            return ret;
        },
        __wbg_new_3eb36ae241fe6f44: function() {
            const ret = new Array();
            return ret;
        },
        __wbg_new_8a6f238a6ece86ea: function() {
            const ret = new Error();
            return ret;
        },
        __wbg_set_3f1d0b984ed272ed: function(arg0, arg1, arg2) {
            arg0[arg1] = arg2;
        },
        __wbg_set_f43e577aea94465b: function(arg0, arg1, arg2) {
            arg0[arg1 >>> 0] = arg2;
        },
        __wbg_stack_0ed75d68575b0f3c: function(arg0, arg1) {
            const ret = arg1.stack;
            const ptr1 = passStringToWasm0(ret, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbindgen_cast_0000000000000001: function(arg0) {
            // Cast intrinsic for `F64 -> Externref`.
            const ret = arg0;
            return ret;
        },
        __wbindgen_cast_0000000000000002: function(arg0, arg1) {
            // Cast intrinsic for `Ref(String) -> Externref`.
            const ret = getStringFromWasm0(arg0, arg1);
            return ret;
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        },
    };
    return {
        __proto__: null,
        "./axis_kernel_wasm_bg.js": import0,
    };
}

const SolidFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_solid_free(ptr >>> 0, 1));

function _assertClass(instance, klass) {
    if (!(instance instanceof klass)) {
        throw new Error(`expected instance of ${klass.name}`);
    }
}

function getArrayF32FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat32ArrayMemory0().subarray(ptr / 4, ptr / 4 + len);
}

function getArrayF64FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getFloat64ArrayMemory0().subarray(ptr / 8, ptr / 8 + len);
}

function getArrayU8FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}

let cachedDataViewMemory0 = null;
function getDataViewMemory0() {
    if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || (cachedDataViewMemory0.buffer.detached === undefined && cachedDataViewMemory0.buffer !== wasm.memory.buffer)) {
        cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
    }
    return cachedDataViewMemory0;
}

let cachedFloat32ArrayMemory0 = null;
function getFloat32ArrayMemory0() {
    if (cachedFloat32ArrayMemory0 === null || cachedFloat32ArrayMemory0.byteLength === 0) {
        cachedFloat32ArrayMemory0 = new Float32Array(wasm.memory.buffer);
    }
    return cachedFloat32ArrayMemory0;
}

let cachedFloat64ArrayMemory0 = null;
function getFloat64ArrayMemory0() {
    if (cachedFloat64ArrayMemory0 === null || cachedFloat64ArrayMemory0.byteLength === 0) {
        cachedFloat64ArrayMemory0 = new Float64Array(wasm.memory.buffer);
    }
    return cachedFloat64ArrayMemory0;
}

function getStringFromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return decodeText(ptr, len);
}

let cachedUint32ArrayMemory0 = null;
function getUint32ArrayMemory0() {
    if (cachedUint32ArrayMemory0 === null || cachedUint32ArrayMemory0.byteLength === 0) {
        cachedUint32ArrayMemory0 = new Uint32Array(wasm.memory.buffer);
    }
    return cachedUint32ArrayMemory0;
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function isLikeNone(x) {
    return x === undefined || x === null;
}

function passArray32ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 4, 4) >>> 0;
    getUint32ArrayMemory0().set(arg, ptr / 4);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passArray8ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 1, 1) >>> 0;
    getUint8ArrayMemory0().set(arg, ptr / 1);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passArrayF32ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 4, 4) >>> 0;
    getFloat32ArrayMemory0().set(arg, ptr / 4);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passArrayF64ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 8, 8) >>> 0;
    getFloat64ArrayMemory0().set(arg, ptr / 8);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

function takeFromExternrefTable0(idx) {
    const value = wasm.__wbindgen_externrefs.get(idx);
    wasm.__externref_table_dealloc(idx);
    return value;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(ptr, len) {
    numBytesDecoded += len;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
        cachedTextDecoder.decode();
        numBytesDecoded = len;
    }
    return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasm;
function __wbg_finalize_init(instance, module) {
    wasm = instance.exports;
    wasmModule = module;
    cachedDataViewMemory0 = null;
    cachedFloat32ArrayMemory0 = null;
    cachedFloat64ArrayMemory0 = null;
    cachedUint32ArrayMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = module.ok && expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;


    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('vcad_kernel_wasm_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
