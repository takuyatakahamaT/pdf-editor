package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

func TestRemapPreservesEveryExplicitDestinationMode(t *testing.T) {
	cases := []struct {
		name        string
		destination string
	}{
		{name: "XYZ", destination: "/XYZ 42 64 1.25"},
		{name: "Fit", destination: "/Fit"},
		{name: "FitH", destination: "/FitH 64"},
		{name: "FitV", destination: "/FitV 42"},
		{name: "FitR", destination: "/FitR 10 20 30 40"},
		{name: "FitB", destination: "/FitB"},
		{name: "FitBH", destination: "/FitBH 64"},
		{name: "FitBV", destination: "/FitBV 42"},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			testRemapPreservesDestination(t, testCase.destination)
		})
	}
}

func testRemapPreservesDestination(t *testing.T, destinationSyntax string) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.pdf")
	input := filepath.Join(dir, "input.pdf")
	output := filepath.Join(dir, "output.pdf")
	mappingsPath := filepath.Join(dir, "mappings.json")
	if err := os.WriteFile(source, twoPageLinkPDF("5 0 R", destinationSyntax), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(input, exportedTwoPageLinkPDF(destinationSyntax), 0600); err != nil {
		t.Fatal(err)
	}
	mappings := []linkRemap{{
		PageIndex:            1,
		LinkIndex:            0,
		Bounds:               [4]float64{20, 100, 100, 118},
		DestinationPageIndex: 2,
	}}
	data, err := json.Marshal(mappings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mappingsPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{source, input, output, mappingsPath}); err != nil {
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
	if !ok || len(destination) < 2 {
		t.Fatalf("destination = %T %v", annotation["Dest"], annotation["Dest"])
	}
	pageRef, ok := destination[0].(types.IndirectRef)
	if !ok || destinationPageRef == nil || pageRef != *destinationPageRef {
		t.Fatalf("destination page = %v, want %v", destination[0], destinationPageRef)
	}
	name, ok := destination[1].(types.Name)
	if !ok || name.Value() != nameFromSyntax(destinationSyntax) {
		t.Fatalf("destination mode = %v", destination[1])
	}
	sourceCtx, err := api.ReadContextFile(context.Background(), source)
	if err != nil {
		t.Fatal(err)
	}
	sourcePageDict, _, _, err := sourceCtx.PageDict(context.Background(), 1, false)
	if err != nil {
		t.Fatal(err)
	}
	sourceAnnots, err := sourceCtx.XRefTable.DereferenceArray(sourcePageDict["Annots"])
	if err != nil || len(sourceAnnots) != 1 {
		t.Fatalf("source annotations = %v, error = %v", sourceAnnots, err)
	}
	sourceAnnotation, err := sourceCtx.XRefTable.DereferenceDict(sourceAnnots[0])
	if err != nil {
		t.Fatal(err)
	}
	sourceDestination, _, err := sourceDestinationArray(sourceCtx, sourceAnnotation)
	if err != nil {
		t.Fatal(err)
	}
	if len(destination) != len(sourceDestination) {
		t.Fatalf("destination length = %d, want %d", len(destination), len(sourceDestination))
	}
	for index := 1; index < len(destination); index++ {
		if destination[index].PDFString() != sourceDestination[index].PDFString() {
			t.Fatalf("destination parameter %d = %s, want %s", index, destination[index].PDFString(), sourceDestination[index].PDFString())
		}
	}
	if _, found := annotation["A"]; found {
		t.Fatal("go-to action was not removed")
	}
}

func TestRejectsMismatchedLinkBounds(t *testing.T) {
	dir := t.TempDir()
	source := filepath.Join(dir, "source.pdf")
	input := filepath.Join(dir, "input.pdf")
	output := filepath.Join(dir, "output.pdf")
	mappingsPath := filepath.Join(dir, "mappings.json")
	if err := os.WriteFile(source, twoPageLinkPDF("5 0 R", "/Fit"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(input, exportedTwoPageLinkPDF("/Fit"), 0600); err != nil {
		t.Fatal(err)
	}
	mappings := []linkRemap{{
		PageIndex:            1,
		LinkIndex:            0,
		Bounds:               [4]float64{0, 0, 1, 1},
		DestinationPageIndex: 2,
	}}
	data, err := json.Marshal(mappings)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(mappingsPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{source, input, output, mappingsPath}); err == nil {
		t.Fatal("mismatched link bounds accepted")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatalf("output exists after rejection: %v", err)
	}
}

func twoPageLinkPDF(secondPageRef, destinationSyntax string) []byte {
	objects := [][]byte{
		[]byte("<< /Type /Catalog /Pages 2 0 R >>"),
		[]byte("<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 4 0 R /Annots [8 0 R] >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 6 0 R >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
		[]byte(fmt.Sprintf("<< /Type /Annot /Subtype /Link /Rect [20 100 100 118] /Dest [%s %s] >>", secondPageRef, destinationSyntax)),
	}
	return rawPDF(objects)
}

func exportedTwoPageLinkPDF(destinationSyntax string) []byte {
	objects := [][]byte{
		[]byte("<< /Type /Catalog /Pages 2 0 R >>"),
		[]byte("<< /Type /Pages /Kids [5 0 R 7 0 R] /Count 2 >>"),
		[]byte("<< /Placeholder true >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 6 0 R /Annots [9 0 R] >>"),
		streamObject("", []byte("")),
		[]byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 160] /Contents 8 0 R >>"),
		streamObject("", []byte("")),
		[]byte(fmt.Sprintf("<< /Type /Annot /Subtype /Link /Rect [20 100 100 118] /A << /S /GoTo /D [ /#23232 %s ] >> >>", destinationSyntax)),
	}
	return rawPDF(objects)
}

func nameFromSyntax(destinationSyntax string) string {
	fields := strings.Fields(destinationSyntax)
	return strings.TrimPrefix(fields[0], "/")
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
