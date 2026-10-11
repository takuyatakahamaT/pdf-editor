// pdf-compress recompresses eligible RGB image streams without rendering pages.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

const maxPixels = 100_000_000

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: pdf-compress input.pdf output.pdf quality(90-98)")
	}
	quality, err := strconv.Atoi(args[2])
	if err != nil || (quality != 0 && (quality < 90 || quality > 98)) {
		return errors.New("JPEG quality must be 90-98, or 0 for lossless optimization")
	}
	input, output := args[0], args[1]
	if samePath(input, output) {
		return errors.New("input and output must be different files")
	}
	if _, err := os.Stat(output); err == nil {
		return errors.New("output already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	ctx, err := api.ReadContextFile(context.Background(), input)
	if err != nil {
		return err
	}
	ids := make([]int, 0, len(ctx.XRefTable.Table))
	for id := range ctx.XRefTable.Table {
		ids = append(ids, id)
	}
	sort.Ints(ids)
	replaced := 0
	for _, id := range ids {
		if quality == 0 {
			break // Keep every original image stream untouched.
		}
		entry := ctx.XRefTable.Table[id]
		if entry == nil {
			continue
		}
		sd, ok := entry.Object.(types.StreamDict)
		if !ok || !sd.Image() || !sd.HasSoleFilterNamed("FlateDecode") || !rgbColorSpace(ctx.XRefTable, sd.Dict) {
			continue
		}
		if _, hasDecode := sd.Dict.Find("Decode"); hasDecode {
			// A custom Decode array can invert or remap samples.
			continue
		}
		if _, imageMask := sd.Dict.Find("ImageMask"); imageMask {
			continue
		}
		w, h, bpc := sd.IntEntry("Width"), sd.IntEntry("Height"), sd.IntEntry("BitsPerComponent")
		if w == nil || h == nil || bpc == nil || *bpc != 8 || *w <= 0 || *h <= 0 || *w > 16_000 || *h > 16_000 || *w > maxPixels / *h {
			continue
		}
		if err := sd.Decode(); err != nil || len(sd.Content) != *w**h*3 {
			continue
		}
		im := image.NewRGBA(image.Rect(0, 0, *w, *h))
		for i := 0; i < *w**h; i++ {
			copy(im.Pix[4*i:4*i+3], sd.Content[3*i:3*i+3])
			im.Pix[4*i+3] = 255
		}
		var encoded bytes.Buffer
		if err := jpeg.Encode(&encoded, im, &jpeg.Options{Quality: quality}); err != nil {
			return err
		}
		if encoded.Len() >= len(sd.Raw) {
			continue
		}
		sd.Raw = encoded.Bytes()
		sd.Content = nil
		sd.FilterPipeline = []types.PDFFilter{{Name: "DCTDecode"}}
		sd.Dict.Update("Filter", types.Name("DCTDecode"))
		sd.Dict.Delete("DecodeParms")
		length := int64(len(sd.Raw))
		sd.StreamLength = &length
		sd.Dict.Update("Length", types.Integer(length))
		entry.Object = sd
		replaced++
	}
	if err := api.WriteContextFile(context.Background(), ctx, output); err != nil {
		_ = os.Remove(output)
		return err
	}
	fmt.Printf("replaced=%d\n", replaced)
	return nil
}

func rgbColorSpace(x *model.XRefTable, dict types.Dict) bool {
	obj, found := dict.Find("ColorSpace")
	if !found {
		return false
	}
	obj, err := x.Dereference(obj)
	if err != nil {
		return false
	}
	if name, ok := obj.(types.Name); ok {
		return name.Value() == "DeviceRGB"
	}
	array, ok := obj.(types.Array)
	if !ok || len(array) != 2 {
		return false
	}
	space, ok := array[0].(types.Name)
	if !ok || space.Value() != "ICCBased" {
		return false
	}
	profile, _, err := x.DereferenceStreamDict(array[1])
	if err != nil || profile == nil {
		return false
	}
	channels := profile.IntEntry("N")
	return channels != nil && *channels == 3
}

func samePath(a, b string) bool {
	left, _ := filepath.Abs(a)
	right, _ := filepath.Abs(b)
	if left == right {
		return true
	}
	if resolved, err := filepath.EvalSymlinks(left); err == nil {
		left = resolved
	}
	if resolved, err := filepath.EvalSymlinks(right); err == nil {
		right = resolved
	}
	if left == right {
		return true
	}
	aInfo, aErr := os.Stat(a)
	bInfo, bErr := os.Stat(b)
	return aErr == nil && bErr == nil && os.SameFile(aInfo, bInfo)
}
