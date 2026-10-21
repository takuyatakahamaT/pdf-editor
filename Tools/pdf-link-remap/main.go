// pdf-link-remap repairs internal link destinations after PDFKit rewrites pages.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/types"
)

type linkRemap struct {
	PageIndex            int        `json:"pageIndex"`
	LinkIndex            int        `json:"linkIndex"`
	Bounds               [4]float64 `json:"bounds"`
	DestinationPageIndex int        `json:"destinationPageIndex"`
	DestinationPoint     [2]float64 `json:"destinationPoint"`
	DestinationZoom      *float64   `json:"destinationZoom"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 3 {
		return errors.New("usage: pdf-link-remap input.pdf output.pdf mappings.json")
	}
	input, output, mappingsPath := args[0], args[1], args[2]
	if samePath(input, output) {
		return errors.New("input and output must be different files")
	}
	mappingData, err := os.ReadFile(mappingsPath)
	if err != nil {
		return err
	}
	var mappings []linkRemap
	if err := json.Unmarshal(mappingData, &mappings); err != nil {
		return fmt.Errorf("read link mappings: %w", err)
	}
	if len(mappings) == 0 {
		return errors.New("no internal link mappings provided")
	}
	ctx, err := api.ReadContextFile(context.Background(), input)
	if err != nil {
		return err
	}
	if ctx.PageCount <= 0 {
		return errors.New("PDF has no pages")
	}
	used := make(map[[2]int]bool, len(mappings))
	for _, mapping := range mappings {
		if err := validateMapping(mapping, ctx.PageCount); err != nil {
			return err
		}
		key := [2]int{mapping.PageIndex, mapping.LinkIndex}
		if used[key] {
			return fmt.Errorf("duplicate link mapping for page %d link %d", mapping.PageIndex, mapping.LinkIndex)
		}
		used[key] = true
		if err := remapLink(ctx, mapping); err != nil {
			return err
		}
	}
	if err := api.WriteContextFile(context.Background(), ctx, output); err != nil {
		return err
	}
	fmt.Printf("remapped=%d\n", len(mappings))
	return nil
}

func validateMapping(mapping linkRemap, pageCount int) error {
	if mapping.PageIndex < 1 || mapping.PageIndex > pageCount || mapping.LinkIndex < 0 {
		return fmt.Errorf("invalid source page or link index: page=%d link=%d", mapping.PageIndex, mapping.LinkIndex)
	}
	if mapping.DestinationPageIndex < 1 || mapping.DestinationPageIndex > pageCount {
		return fmt.Errorf("invalid destination page index: %d", mapping.DestinationPageIndex)
	}
	for _, value := range mapping.Bounds {
		if !finite(value) {
			return errors.New("link bounds contain a non-finite value")
		}
	}
	for _, value := range mapping.DestinationPoint {
		if !finite(value) {
			return errors.New("destination point contains a non-finite value")
		}
	}
	if mapping.DestinationZoom != nil && (!finite(*mapping.DestinationZoom) || *mapping.DestinationZoom <= 0) {
		return errors.New("destination zoom must be finite and positive")
	}
	return nil
}

func remapLink(ctx *model.Context, mapping linkRemap) error {
	pageDict, _, _, err := ctx.PageDict(context.Background(), mapping.PageIndex, false)
	if err != nil {
		return err
	}
	annotsObject, found := pageDict.Find("Annots")
	if !found {
		return fmt.Errorf("page %d has no annotations", mapping.PageIndex)
	}
	annots, err := ctx.XRefTable.DereferenceArray(annotsObject)
	if err != nil {
		return fmt.Errorf("read annotations on page %d: %w", mapping.PageIndex, err)
	}
	linkIndex := 0
	for _, annotationObject := range annots {
		annotationDict, err := ctx.XRefTable.DereferenceDict(annotationObject)
		if err != nil {
			return fmt.Errorf("read annotation on page %d: %w", mapping.PageIndex, err)
		}
		if nameValue(annotationDict["Subtype"]) != "Link" {
			continue
		}
		if linkIndex == mapping.LinkIndex {
			if err := validateBounds(ctx, annotationDict, mapping); err != nil {
				return err
			}
			return setDestination(ctx, annotationDict, mapping)
		}
		linkIndex++
	}
	return fmt.Errorf("page %d has no link annotation at index %d", mapping.PageIndex, mapping.LinkIndex)
}

func validateBounds(ctx *model.Context, annotation types.Dict, mapping linkRemap) error {
	object, found := annotation.Find("Rect")
	if !found {
		return fmt.Errorf("page %d link %d has no bounds", mapping.PageIndex, mapping.LinkIndex)
	}
	actual, err := ctx.XRefTable.DereferenceArray(object)
	if err != nil || len(actual) != 4 {
		return fmt.Errorf("page %d link %d has invalid bounds", mapping.PageIndex, mapping.LinkIndex)
	}
	for index, value := range actual {
		number, ok := pdfNumber(value)
		if !ok || math.Abs(number-mapping.Bounds[index]) > 0.05 {
			return fmt.Errorf("page %d link %d bounds do not match the source", mapping.PageIndex, mapping.LinkIndex)
		}
	}
	return nil
}

func setDestination(ctx *model.Context, annotation types.Dict, mapping linkRemap) error {
	_, destinationPageRef, _, err := ctx.PageDict(context.Background(), mapping.DestinationPageIndex, false)
	if err != nil || destinationPageRef == nil {
		return fmt.Errorf("resolve destination page %d: %w", mapping.DestinationPageIndex, err)
	}
	destination := types.Array{
		*destinationPageRef,
		types.Name("XYZ"),
		types.Float(mapping.DestinationPoint[0]),
		types.Float(mapping.DestinationPoint[1]),
	}
	if mapping.DestinationZoom == nil {
		destination = append(destination, nil)
	} else {
		destination = append(destination, types.Float(*mapping.DestinationZoom))
	}
	delete(annotation, "A")
	annotation["Dest"] = destination
	return nil
}

func nameValue(object types.Object) string {
	name, _ := object.(types.Name)
	return name.Value()
}

func pdfNumber(object types.Object) (float64, bool) {
	switch number := object.(type) {
	case types.Float:
		return float64(number), true
	case types.Integer:
		return float64(number), true
	default:
		return 0, false
	}
}

func finite(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

func samePath(left, right string) bool {
	leftAbs, _ := filepath.Abs(left)
	rightAbs, _ := filepath.Abs(right)
	if leftAbs == rightAbs {
		return true
	}
	leftInfo, leftErr := os.Stat(left)
	rightInfo, rightErr := os.Stat(right)
	return leftErr == nil && rightErr == nil && os.SameFile(leftInfo, rightInfo)
}
