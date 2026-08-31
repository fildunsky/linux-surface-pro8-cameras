# Getting the factory calibration for your own device

The colour matrices and white balance curve in `tuning/` are derived from
Intel `.aiqb` calibration blobs that ship inside Microsoft's Windows
driver package. Those blobs are per-module: they were measured on the
exact camera in the exact device they came with. Ours are not right for
your unit, and they are not redistributable, so extract your own.

Nothing here touches Windows or requires it to be installed — everything
is done from Linux against a downloaded driver package.

## 1. Find out which blobs your device needs

The camera modules are identified by ACPI ids in your own firmware:

```sh
sudo grep -aoE 'MSHW0[0-9]{3}' /sys/firmware/acpi/tables/DSDT | sort -u
```

On a Surface Pro 8 this prints three ids, one per camera:

```
MSHW0260    front       -> OV5693_MSHW0260_TGL.aiqb
MSHW0261    rear        -> OV13858_MSHW0261_TGL.aiqb
MSHW0262    infrared    -> VD55G0_MSHW0262_TGL.aiqb
```

The blob file names follow the pattern `<sensor>_<MSHW id>_<platform>.aiqb`.
On a different Surface model you will get different ids and different
sensors, but the same naming scheme.

## 2. Download the driver package

Microsoft publishes per-model driver and firmware packs as `.msi`:

<https://www.microsoft.com/en-us/download/details.aspx?id=104114>

Pick your model and Windows version, for example
`SurfacePro8_Win11_<build>_<version>.msi`. You need the file only; you do
not need to run it.

## 3. Extract the blobs

The `.msi` is a compound file containing cab archives, and the files
inside carry mangled names of the form `fil<32 hex digits>`. The mapping
back to real names lives in the MSI's own `!File` table.

```sh
sudo apt install p7zip-full

# unpack everything, including the internal tables
mkdir -p msi && cd msi
7z x -y ../SurfacePro8_Win11_*.msi

# the tables come out with a leading '!' which is awkward in the shell
mkdir -p tables
cp '!File' '!_StringData' '!_StringPool' tables/ 2>/dev/null
cd tables && for f in '!'*; do mv "$f" "${f#!}"; done; cd ..

# map mangled names to real ones and find the calibration blobs
../tools/msi-filenames.py tables | grep -i aiqb
```

That prints lines like:

```
fil3f2a...c9   OV5693_MSHW0260_TGL.aiqb
```

Copy the mangled files out under their real names:

```sh
mkdir -p ../factory-tuning
../tools/msi-filenames.py tables | grep -i aiqb | while read mangled real; do
    find . -name "$mangled" -exec cp {} "../factory-tuning/$real" \;
done
ls -l ../factory-tuning/
```

Sanity check — a valid blob starts with the CPFF container magic and is
tens to hundreds of kilobytes:

```sh
head -c 4 factory-tuning/OV5693_*.aiqb | xxd
```

## 4. Generate tuning files

```sh
./tools/factory-tuning.py factory-tuning/OV5693_MSHW0260_TGL.aiqb   # inspect
./tools/factory-tuning.py factory-tuning/OV5693_MSHW0260_TGL.aiqb - tuning/ov5693.yaml
sudo cp tuning/*.yaml /usr/share/libcamera/ipa/simple/
```

Called with just the file, the tool prints what it found — one row per
illuminant, with the raw grey-card ratios and the white balance gains they
imply:

```
   CCT  raw R/G  raw B/G   white balance
  2514   1.0186   0.4678   gR=0.982 gB=2.138
  2848   0.8768   0.4779   gR=1.141 gB=2.093
  ...
```

If that table looks like nonsense — ratios outside roughly 0.2 to 4, or
absurd colour temperatures — the extraction went wrong; check that you
copied the right mangled file.

The infrared camera has no illuminants and no matrices, which is correct:
it is a monochrome sensor.

## 5. Look deeper, if you want

`tools/decode_aiqb.py` dumps the container structure: every record with
its offset, size and numeric id, plus decoders for the noise model and the
per-algorithm ISP tuning blocks.

Records worth knowing about:

| id | what |
|---|---|
| 25 | advanced colour matrices — what we use: per-illuminant CCM and grey-card ratios |
| 28, 33 | lens shading tables, 63x47 nodes, 4 channels. libcamera's software ISP has no LSC algorithm, so unused |
| 31 | global black level, per Bayer channel, in 10-bit DN |
| 264 | duplicates 25 and adds two unidentified scalars per illuminant, possibly saturation and contrast |

The `LISP` section holds per-algorithm ISP tuning keyed by opaque UUIDs.
Sharpening and noise reduction are almost certainly in there, but the
UUID-to-algorithm mapping is internal to Intel's tooling and we could not
recover it. libcamera's software ISP has neither algorithm anyway.

Note when using `decode_aiqb.py` directly: its default mode
(`decode_advanced_ccm`) only gets the first illuminant right and then
drifts, because it miscalculates the stride when the number of hue-sector
matrices varies. `factory-tuning.py` does its own scan and is correct.
