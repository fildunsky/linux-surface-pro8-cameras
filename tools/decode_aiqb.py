#!/usr/bin/env python3
"""Decode Intel CPFF/.aiqb OEM camera tuning (Surface Pro 7+ modules).

The CMC record chain starts at file offset 0x50 (right after the CPFF header
block). Records: size(u32), data_format_id(u8), key_id(u8), name_id(u16).
name_id 25 = advanced color matrices: per light source a 20-byte info
(src_type u32, chromaticity R/G,B/G float, CIE x,y float) followed by a
'traditional' 3x3 float CCM (rows sum to 1) and sector_count hue-sector CCMs.

The chromaticity IS the sensor white point per illuminant: AWB gains = 1/chroma.
CCT is not stored; derive it from CIE xy (McCamy). Usage:
    ./decode_aiqb.py OV5693_MSHW0220_TGL.aiqb            # CCMs (nid 25), como siempre
    ./decode_aiqb.py file.aiqb --records                 # tabla completa de records
    ./decode_aiqb.py file.aiqb --noise                   # modelo de ruido + black level + gains
    ./decode_aiqb.py file.aiqb --isp                     # seccion LISP (tuning ISP por stream)

Estructura CPFF (descubierta 2026-08-27, ver ia_cmc_types.h / ia_mkn_types.h):
  0x00 'CPFF' + size + ... + checksum_u32@0x14 (suma autoexcluyente del fichero)
  Contenedores anidados {tag u32, size u32 (desde el propio header), ver u32, pad u32}:
    LCMC > DFLT > AIQB(records CMC, enum cmc_name_id)      <- calibracion del modulo
    LAIQ > DFLT|ULL3 > AIQB(records 257..267 = ia_aiq)     <- tuning 3A
    LISP > DFLT|LMOD1|LMOD2 > AIQB(records nid=stream_id   <- tuning ISP (NR, sharpening...)
           60000/60001/60005; dentro, sub-records por uuid de algoritmo)
    LTHR > DFLT|ULL3 > AIQB(records 705..720, umbrales)
  El header AIQB mide 0x18 (incluye checksum de seccion en +0x14); LCMC/DFLT/
  LAIQ/LISP/LMOD/ULL3/LTHR miden 0x10. Record: size u32, fmt u8, key u8, nid u16.
"""
import json
import struct
import sys

LS = {0: 'none', 1: 'A/tungsten', 2: 'B', 3: 'C', 4: 'D50', 5: 'D55',
      6: 'D65', 7: 'D75', 8: 'E', 9: 'F1', 10: 'F2/coolwhite', 11: 'F3',
      12: 'F4/warmwhite', 13: 'F5', 14: 'F6', 15: 'F7/D65sim', 16: 'F8',
      17: 'F9', 18: 'F10', 19: 'F11/TL84', 20: 'F12'}


def mccamy_cct(x, y):
    n = (x - 0.3320) / (0.1858 - y)
    return 449 * n**3 + 3525 * n**2 + 6823.3 * n + 5520.33


def walk_records(d, start=0x50):
    off = start
    while off + 8 <= len(d):
        size, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
        if size < 8 or off + size > len(d) or nid > 200:
            return
        yield off, size, fmt, key, nid
        off += size


def decode_advanced_ccm(d, off):
    body = off + 8
    nls, nsec = struct.unpack_from('<HH', d, body)
    p = body + 4 + nsec * 4  # skip hue_of_sectors
    out = []
    for _ in range(nls):
        src, = struct.unpack_from('<I', d, p)
        rg, bg, cx, cy = struct.unpack_from('<4f', d, p + 4)
        trad = struct.unpack_from('<9f', d, p + 20)
        out.append({'src': LS.get(src, str(src)),
                    'cct': round(mccamy_cct(cx, cy)),
                    'rpg': round(rg, 4), 'bpg': round(bg, 4),
                    'awb_gains': [round(1 / rg, 4), round(1 / bg, 4)],
                    'ccm': [round(v, 4) for v in trad]})
        p += 20 + 36 + nsec * 36
    return sorted(out, key=lambda e: e['cct'])


CMC_NAMES = {
    0: 'reserved', 1: 'comment', 2: 'general_data', 3: 'black_level',
    4: 'black_level_spatial', 5: 'saturation_level',
    6: 'dynamic_range_and_linearity', 7: 'module_sensitivity',
    8: 'defect_pixels', 9: 'noise', 10: 'lsc', 11: 'lsc_ratio', 12: 'gdc',
    13: 'optics_and_mechanics', 14: 'module_spectral_response',
    15: 'chromaticity_response', 16: 'flash_chromaticity', 17: 'nvm_info',
    18: 'color_matrices', 19: 'analog_gain_conversion', 20: 'digital_gain',
    21: 'sensor_metadata', 22: 'gdc2', 23: 'exposure_range',
    24: 'multi_led_flash_chromaticity', 25: 'advanced_color_matrices',
    26: 'hdr', 27: 'infrared_correction', 28: 'lsc_4x4',
    29: 'lat_chromatic_aberration', 30: 'phase_difference',
    31: 'black_level_global', 32: 'valid_image_area', 33: 'lsc_4x4_ratio',
    34: 'multi_gain_conversions', 35: 'pipe_comp_decomp',
    36: 'sensor_decomp', 37: 'media_format', 38: 'cbd'}

SECTION_TAGS = (b'LCMC', b'DFLT', b'AIQB', b'LAIQ', b'LISP', b'LMOD',
                b'LTHR', b'ULL3')


def walk_sections(d):
    """Yield (path, chain_start, chain_end) for every AIQB record chain.

    Containers are consecutive headers {tag,size,ver,pad}; size runs from the
    header itself to the container end. AIQB headers are 0x18 (checksum at
    +0x14), the rest 0x10. Nesting: Lxxx > mode (DFLT/ULL3/LMODn) > AIQB.
    """
    p, path = 0x18, []
    while p + 16 <= len(d):
        tag = d[p:p + 4]
        if tag not in SECTION_TAGS:
            break
        size, ver = struct.unpack_from('<II', d, p + 4)
        end = p + size
        while path and path[-1][1] <= p:
            path.pop()
        name = tag.decode()
        if tag in (b'LMOD', b'ULL3', b'DFLT'):
            name += str(ver) if tag == b'LMOD' else ''
        if tag == b'AIQB':
            yield '/'.join(t for t, _ in path), p + 0x18, end
            p = end
        else:
            path.append((name, end))
            p += 16


def walk_chain(d, start, end):
    off = start
    while off + 8 <= end:
        size, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
        if size < 8 or off + size > end:
            return
        yield off, size, fmt, key, nid
        off += size


def cmd_records(d):
    for path, start, end in walk_sections(d):
        print(f'== {path or "LCMC"}  [{start:#x}..{end:#x}]')
        for off, size, fmt, key, nid in walk_chain(d, start, end):
            name = CMC_NAMES.get(nid, '') if path.startswith('LCMC') else ''
            print(f'  {off:#07x} size={size:6d} fmt={fmt:3d} nid={nid:5d} {name}')


def decode_noise_model(d, off):
    """nid 9: y = c1*x^2 + G*c2*x + G^2*c3 + G*c4 + c5 (x = media, y = var).
    Calibrado por MS sobre el RAW alineado a 12 bits de Windows: c1 = PRNU^2,
    c2 = ganancia de conversion (DN12/e-), c4+c5 = ruido de lectura (DN12^2)."""
    c = struct.unpack_from('<5f', d, off + 8)
    return {'c1_prnu2': c[0], 'c2_shot': c[1], 'c3': c[2], 'c4': c[3],
            'c5': c[4]}


def decode_black_level(d, off):
    """nid 3: num_bl_luts u32 + LUTs {exp_us u32, again_q16 u32, 4x u16 Q8.8}."""
    num, = struct.unpack_from('<I', d, off + 8)
    p, out = off + 12, []
    for _ in range(num):
        e, g = struct.unpack_from('<II', d, p)
        cc = struct.unpack_from('<4H', d, p + 8)
        out.append({'exp_us': e, 'again': round(g / 65536, 2),
                    'bl_q8.8': [round(v / 256, 2) for v in cc]})
        p += 16
    return out


def decode_gain_conversions(d, off_ag, off_dg):
    """nid 19 (SMIA analog gain segments) + nid 20 (digital gain limits)."""
    out = {}
    if off_ag:
        ct, _, nseg, npair = struct.unpack_from('<4H', d, off_ag + 8)
        segs = []
        p = off_ag + 16
        for _ in range(nseg):
            gb, ge, cmin, cmax, cstep = struct.unpack_from('<5I', d, p)
            m0, c0, m1, c1 = struct.unpack_from('<4h', d, p + 20)
            segs.append({'gain': [gb / 65536, ge / 65536],
                         'code': [cmin, cmax], 'step': cstep,
                         'M0C0M1C1': [m0, c0, m1, c1]})
            p += 28
        out['analog'] = {'type': ct, 'segments': segs}
    if off_dg:
        dmin, dmax = struct.unpack_from('<2H', d, off_dg + 8)
        step, frac = d[off_dg + 12], d[off_dg + 13]
        out['digital'] = {'min_code': dmin, 'max_code': dmax, 'step': step,
                          'fraction_bits': frac,
                          'range_x': [dmin / (1 << frac), dmax / (1 << frac)]}
    return out


def cmd_noise(d):
    offs = {nid: off for off, _, _, _, nid in walk_records(d)}
    out = {}
    if 2 in offs:
        w, h, bits, order, packed = struct.unpack_from('<5H', d, offs[2] + 8)
        out['general'] = {'w': w, 'h': h, 'bit_depth': bits,
                          'bit_depth_packed': packed}
    if 7 in offs:
        out['base_iso'] = struct.unpack_from('<H', d, offs[7] + 8)[0]
    if 9 in offs:
        out['noise_model'] = decode_noise_model(d, offs[9])
    if 3 in offs:
        out['black_level'] = decode_black_level(d, offs[3])
    out['gain_conversion'] = decode_gain_conversions(
        d, offs.get(19), offs.get(20))
    json.dump(out, sys.stdout, indent=1)
    print()


def cmd_isp(d):
    """LISP: por stream (nid=stream_id del graph), sub-records por uuid de
    algoritmo: {size u32, 0x0064 u16, 0x8000 u16, uuid u32, ver u32,
    n_nodes u32, ? u32, n_pts u32, ejes float...}. Los ejes [1,2,4,8,~16]
    son nodos de GANANCIA ANALOGICA: el tuning NR/sharpen se interpola por
    la ganancia del AE. Los uuid son del namespace interno del IQ tool de
    Intel (no coinciden con ia_pal_uuid); no hay mapeo publico a nombres."""
    for path, start, end in walk_sections(d):
        if not path.startswith('LISP'):
            continue
        for off, size, fmt, key, nid in walk_chain(d, start, end):
            print(f'== {path} stream {nid} ({size} bytes)')
            algos = {}
            p = off + 8
            while p + 16 <= off + size:
                ssz, tag, flags, uuid, ver = struct.unpack_from('<IHHII', d, p)
                if ssz < 16 or p + ssz > off + size:
                    break
                nn, = struct.unpack_from('<I', d, p + 16)
                ax = struct.unpack_from(f'<{min(nn, 8)}f', d, p + 28)
                a = algos.setdefault(uuid, {'n': 0, 'bytes': 0, 'axis': ax})
                a['n'] += 1
                a['bytes'] += ssz
                p += ssz
            for uuid, a in sorted(algos.items(), key=lambda kv: -kv[1]['bytes']):
                ax = ', '.join(f'{v:g}' for v in a['axis'])
                print(f'   uuid {uuid:5d} x{a["n"]:3d} {a["bytes"]:6d} B'
                      f'  nodos[{ax}]')


def main():
    d = open(sys.argv[1], 'rb').read()
    assert d[:4] == b'CPFF', 'not a CPFF file'
    mode = sys.argv[2] if len(sys.argv) > 2 else ''
    if mode == '--records':
        return cmd_records(d)
    if mode == '--noise':
        return cmd_noise(d)
    if mode == '--isp':
        return cmd_isp(d)
    for off, size, fmt, key, nid in walk_records(d):
        if nid == 25:
            res = decode_advanced_ccm(d, off)
            json.dump(res, sys.stdout, indent=1)
            print()
            return
    print('no advanced-CCM record (name_id 25) found', file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
