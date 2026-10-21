package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

func TestRemapWritesDirectPageDestination(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "input.pdf")
	output := filepath.Join(dir, "output.pdf")
	mappingsPath := filepath.Join(dir, "mappings.json")
	if err := os.WriteFile(input, twoPageLinkPDF(), 0600); err != nil {
		t.Fatal(err)
	}
	zoom := 1.25
	mappings := []linkRemap{{
		PageIndex:            1,
		LinkIndex:            0,
		Bounds:               [4]float64{20, 100, 100, 118},
		DestinationPageIndex: 2,
		DestinationPoint:     [2]float64{42, 64},
		DestinationZoom:      &zoom,
	}}
	data, err := json.Marshal(mappings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mappingsPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{input, output, mappingsPath}); err != nil {
		t.Fatal(err)
	}

	ctx, err := api.ReadContextFile(context.Background(), output)
	if err != nil {
		t.Fatal(err)
	}
	sourcePage, _, _, err := ctx.PageDict(context.Background(), 1, false)
	if err != nil {
		t.Fatal(err)
	}
	_, destinationPageRef, _, err := ctx.PageDict(context.Background(), 2, false)
	if err != nil {
		t.Fatal(err)
	}
	annots, err := ctx.XRefTable.DereferenceArray(sourcePage["Annots"])
	if err != nil || len(annots) != 1 {
		t.Fatalf("annotations = %v, error = %v", annots, err)
	}
	annotation, err := ctx.XRefTable.DereferenceDict(annots[0])
	if err != nil {
		t.Fatal(err)
	}
	destination, ok := annotation["Dest"].(types.Array)
	if !ok || len(destination) != 5 {
		t.Fatalf("destination = %T %v", annotation["Dest"], annotation["Dest"])
	}
	pageRef, ok := destination[0].(types.IndirectRef)
	if !ok || destinationPageRef == nil || pageRef != *destinationPageRef {
		t.Fatalf("destination page = %v, want %v", destination[0], destinationPageRef)
	}
	if name, ok := destination[1].(types.Name); !ok || name.Value() != "XYZ" {
		t.Fatalf("destination mode = %v", destination[1])
	}
	if x, ok := pdfNumber(destination[2]); !ok || x != 42 {
		t.Fatalf("destination x = %v", destination[2])
	}
	if y, ok := pdfNumber(destination[3]); !ok || y != 64 {
		t.Fatalf("destination y = %v", destination[3])
	}
	if zoom, ok := pdfNumber(destination[4]); !ok || zoom != 1.25 {
		t.Fatalf("destination zoom = %v", destination[4])
	}
	if _, found := annotation["A"]; found {
		t.Fatal("go-to action was not removed")
	}
}

func TestRejectsMismatchedLinkBounds(t *testing.T) {
	dir := t.TempDir()
	input := filepath.Join(dir, "input.pdf")
	output := filepath.Join(dir, "output.pdf")
	mappingsPath := filepath.Join(dir, "mappings.json")
	if err := os.WriteFile(input, twoPageLinkPDF(), 0600); err != nil {
		t.Fatal(err)
	}
	mappings := []linkRemap{{
		PageIndex:            1,
		LinkIndex:            0,
		Bounds:               [4]float64{0, 0, 1, 1},
		DestinationPageIndex: 2,
		DestinationPoint:     [2]float64{42, 64},
	}}
	data, err := json.Marshal(mappings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mappingsPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{input, output, mappingsPath}); err == nil {
		t.Fatal("mismatched link bounds accepted")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("output exists after rejection: %v", err)
	}
}

func twoPageLinkPDF() []byte {
	objects := [][]byte{
		[]byte("<< /Type /Catalog /Pages 2 0 R >>"),
		[]byte("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 4 0 R /Annots [8 0 R] >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 6 0 R >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
		[]byte("<< /Type /Annot /Subtype /Link /Rect [20 100 100 118] /A << /S /GoTo /D [ /#23232 /XYZ 42 64 1.25 ] >> >>"),
	}
	return rawPDF(objects)
}

func streamObject(dict string, content []byte) []byte {
	return []byte(fmt.Sprintf("<< %s /Length %d >>\nstream\n%s\nendstream", dict, len(content), content))
}

func rawPDF(objects [][]byte) []byte {
	var out []byte
	out = append(out, []byte("%PDF-1.4\n")...)
	offsets := make([]int, len(objects))
	for index, object := range objects {
		offsets[index] = len(out)
		out = append(out, []byte(fmt.Sprintf("%d 0 obj\n", index+1))...)
		out = append(out, object...)
		out = append(out, []byte("\nendobj\n")...)
	}
	xref := len(out)
	out = append(out, []byte(fmt.Sprintf("xref\n0 %d\n0000000000 65535 f \n", len(objects)+1))...)
	for _, offset := range offsets {
		out = append(out, []byte(fmt.Sprintf("%010d 00000 n \n", offset))...)
	}
	out = append(out, []byte(fmt.Sprintf("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF", len(objects)+1, xref))...)
	return out
}
