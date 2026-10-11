package main

import (
	"bytes"
	"compress/zlib"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

func TestCompressPreservesPageAndImageDimensions(t *testing.T) {
	dir := t.TempDir()
	input, output := filepath.Join(dir, "input.pdf"), filepath.Join(dir, "output.pdf")
	const width, height = 128, 128
	pixels := make([]byte, width*height*3)
	for y := range height {
		for x := range width {
			i := (y*width + x) * 3
			pixels[i] = byte(x*2 + y/4)
			pixels[i+1] = byte(y*2 + x/4)
			pixels[i+2] = byte((x + y) * 2)
		}
	}
	var compressed bytes.Buffer
	zw := zlib.NewWriter(&compressed)
	if _, err := zw.Write(pixels); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	objects := [][]byte{
		[]byte("<< /Type /Catalog /Pages 2 0 R >>"),
		[]byte("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R] >>"),
		stream("", []byte("q 200 0 0 300 0 0 cm /Im1 Do Q")),
		stream(fmt.Sprintf("/Type /XObject /Subtype /Image /Width %d /Height %d /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode", width, height), compressed.Bytes()),
		[]byte("<< /Type /Annot /Subtype /Text /Rect [10 10 20 20] /Contents (test note) >>"),
	}
	if err := os.WriteFile(input, rawPDF(objects), 0600); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := run([]string{input, output, "95"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(input)
	if err != nil || !bytes.Equal(got, original) {
		t.Fatal("source changed")
	}
	ctx, err := api.ReadContextFile(context.Background(), output)
	if err != nil {
		t.Fatal(err)
	}
	if ctx.PageCount != 1 {
		t.Fatalf("page count = %d", ctx.PageCount)
	}
	image, ok := ctx.XRefTable.Table[5].Object.(types.StreamDict)
	if !ok || !image.HasSoleFilterNamed("DCTDecode") || *image.IntEntry("Width") != width || *image.IntEntry("Height") != height {
		t.Fatal("image dimensions or JPEG filter changed")
	}
	page, _, _, err := ctx.PageDict(context.Background(), 1, false)
	if err != nil {
		t.Fatal(err)
	}
	if page == nil || page.ArrayEntry("Annots") == nil || page.ArrayEntry("MediaBox") == nil {
		t.Fatal("page structure lost")
	}
	lossless := filepath.Join(dir, "lossless.pdf")
	if err := run([]string{input, lossless, "0"}); err != nil {
		t.Fatal(err)
	}
	losslessCtx, err := api.ReadContextFile(context.Background(), lossless)
	if err != nil {
		t.Fatal(err)
	}
	losslessImage, ok := losslessCtx.XRefTable.Table[5].Object.(types.StreamDict)
	if !ok || !losslessImage.HasSoleFilterNamed("FlateDecode") || !bytes.Equal(losslessImage.Raw, compressed.Bytes()) {
		t.Fatal("lossless mode changed the original image stream")
	}
}

func TestRejectsAliasesAndInvalidQuality(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "in.pdf")
	alias := filepath.Join(dir, "alias.pdf")
	if err := os.WriteFile(input, []byte("sentinel"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(input, alias); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{input, alias, "95"}); err == nil {
		t.Fatal("hard link alias accepted")
	}
	if err := run([]string{input, filepath.Join(dir, "out.pdf"), "89"}); err == nil {
		t.Fatal("invalid quality accepted")
	}
	got, _ := os.ReadFile(input)
	if string(got) != "sentinel" {
		t.Fatal("source changed")
	}
}

func stream(dict string, content []byte) []byte {
	return append([]byte(fmt.Sprintf("<< %s /Length %d >>\nstream\n", dict, len(content))), append(content, []byte("\nendstream")...)...)
}

func rawPDF(objects [][]byte) []byte {
	var out bytes.Buffer
	out.WriteString("%PDF-1.4\n")
	offsets := make([]int, len(objects))
	for i, object := range objects {
		offsets[i] = out.Len()
		fmt.Fprintf(&out, "%d 0 obj\n", i+1)
		out.Write(object)
		out.WriteString("\nendobj\n")
	}
	xref := out.Len()
	fmt.Fprintf(&out, "xref\n0 %d\n0000000000 65535 f \n", len(objects)+1)
	for _, offset := range offsets {
		fmt.Fprintf(&out, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&out, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF", len(objects)+1, xref)
	return out.Bytes()
}
