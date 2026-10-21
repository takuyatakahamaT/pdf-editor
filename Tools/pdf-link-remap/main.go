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
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 4 {
		return errors.New("usage: pdf-link-remap source.pdf input.pdf output.pdf mappings.json")
	}
	sourcePath, inputPath, outputPath, mappingsPath := args[0], args[1], args[2], args[3]
	if samePath(sourcePath, outputPath) || samePath(inputPath, outputPath) {
		return errors.New("source and output files must be different")
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
	sourceContext, err := api.ReadContextFile(context.Background(), sourcePath)
	if err != nil {
		return err
	}
	outputContext, err := api.ReadContextFile(context.Background(), inputPath)
	if err != nil {
		return err
	}
	if sourceContext.PageCount <= 0 || outputContext.PageCount <= 0 {
		return errors.New("PDF has no pages")
	}
	if sourceContext.PageCount != outputContext.PageCount {
		return errors.New("output page count does not match source")
	}
	used := make(map[[2]int]bool, len(mappings))
	for _, mapping := range mappings {
		if err := validateMapping(mapping, sourceContext.PageCount); err != nil {
			return err
		}
		key := [2]int{mapping.PageIndex, mapping.LinkIndex}
		if used[key] {
			return fmt.Errorf("duplicate link mapping for page %d link %d", mapping.PageIndex, mapping.LinkIndex)
		}
		used[key] = true
		if err := remapLink(sourceContext, outputContext, mapping); err != nil {
			return err
		}
	}
	if err := api.WriteContextFile(context.Background(), outputContext, outputPath); err != nil {
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
	return nil
}

func remapLink(sourceContext, outputContext *model.Context, mapping linkRemap) error {
	sourceAnnotation, err := linkAnnotation(sourceContext, mapping)
	if err != nil {
		return err
	}
	destination, fromAction, err := sourceDestinationArray(sourceContext, sourceAnnotation)
	if err != nil {
		return fmt.Errorf("resolve source link destination on page %d link %d: %w", mapping.PageIndex, mapping.LinkIndex, err)
	}
	destinationPageIndex, err := pageIndexForReference(sourceContext, destination[0])
	if err != nil {
		return fmt.Errorf("resolve source link page on page %d link %d: %w", mapping.PageIndex, mapping.LinkIndex, err)
	}
	if destinationPageIndex != mapping.DestinationPageIndex {
		return fmt.Errorf("source link destination page mismatch: got %d, expected %d", destinationPageIndex, mapping.DestinationPageIndex)
	}
	outputAnnotation, err := linkAnnotation(outputContext, mapping)
	if err != nil {
		return err
	}
	_, destinationPageRef, _, err := outputContext.PageDict(context.Background(), destinationPageIndex, false)
	if err != nil || destinationPageRef == nil {
		return fmt.Errorf("resolve output destination page %d: %w", destinationPageIndex, err)
	}
	remappedDestination := make(types.Array, len(destination))
	copy(remappedDestination, destination)
	remappedDestination[0] = *destinationPageRef
	if fromAction {
		actionObject, found := outputAnnotation.Find("A")
		if !found {
			return fmt.Errorf("output link on page %d link %d has no go-to action", mapping.PageIndex, mapping.LinkIndex)
		}
		action, err := outputContext.XRefTable.DereferenceDict(actionObject)
		if err != nil {
			return err
		}
		action["D"] = remappedDestination
		delete(outputAnnotation, "Dest")
	} else {
		delete(outputAnnotation, "A")
		outputAnnotation["Dest"] = remappedDestination
	}
	return nil
}

func linkAnnotation(ctx *model.Context, mapping linkRemap) (types.Dict, error) {
	pageDict, _, _, err := ctx.PageDict(context.Background(), mapping.PageIndex, false)
	if err != nil {
		return nil, err
	}
	annotsObject, found := pageDict.Find("Annots")
	if !found {
		return nil, fmt.Errorf("page %d has no annotations", mapping.PageIndex)
	}
	annots, err := ctx.XRefTable.DereferenceArray(annotsObject)
	if err != nil {
		return nil, fmt.Errorf("read annotations on page %d: %w", mapping.PageIndex, err)
	}
	linkIndex := 0
	for _, annotationObject := range annots {
		annotationDict, err := ctx.XRefTable.DereferenceDict(annotationObject)
		if err != nil {
			return nil, fmt.Errorf("read annotation on page %d: %w", mapping.PageIndex, err)
		}
		if nameValue(annotationDict["Subtype"]) != "Link" {
			continue
		}
		if linkIndex == mapping.LinkIndex {
			if err := validateBounds(ctx, annotationDict, mapping); err != nil {
				return nil, err
			}
			return annotationDict, nil
		}
		linkIndex++
	}
	return nil, fmt.Errorf("page %d has no link annotation at index %d", mapping.PageIndex, mapping.LinkIndex)
}

func sourceDestinationArray(ctx *model.Context, annotation types.Dict) (types.Array, bool, error) {
	object, found := annotation.Find("Dest")
	fromAction := false
	if !found {
		actionObject, hasAction := annotation.Find("A")
		if !hasAction {
			return nil, false, errors.New("link has no destination")
		}
		action, err := ctx.XRefTable.DereferenceDict(actionObject)
		if err != nil {
			return nil, false, err
		}
		if nameValue(action["S"]) != "GoTo" {
			return nil, false, errors.New("link action is not an internal go-to")
		}
		object, found = action.Find("D")
		if !found {
			return nil, false, errors.New("go-to action has no destination")
		}
		fromAction = true
	}
	object, err := ctx.XRefTable.Dereference(object)
	if err != nil {
		return nil, false, err
	}
	switch value := object.(type) {
	case types.Array:
		return value, fromAction, nil
	case types.Name:
		array, err := ctx.XRefTable.DereferenceDestArray(context.Background(), value.Value())
		return array, fromAction, err
	case types.StringLiteral:
		name, err := types.StringLiteralToString(value)
		if err != nil {
			return nil, false, err
		}
		array, err := ctx.XRefTable.DereferenceDestArray(context.Background(), name)
		return array, fromAction, err
	case types.HexLiteral:
		name, err := types.HexLiteralToString(value)
		if err != nil {
			return nil, false, err
		}
		array, err := ctx.XRefTable.DereferenceDestArray(context.Background(), name)
		return array, fromAction, err
	default:
		return nil, false, fmt.Errorf("unsupported destination value %T", object)
	}
}

func pageIndexForReference(ctx *model.Context, object types.Object) (int, error) {
	pageRef, ok := object.(types.IndirectRef)
	if !ok {
		if pointer, pointerOK := object.(*types.IndirectRef); pointerOK && pointer != nil {
			pageRef, ok = *pointer, true
		}
	}
	if !ok {
		return 0, fmt.Errorf("destination does not start with a page reference: %T", object)
	}
	for pageIndex := 1; pageIndex <= ctx.PageCount; pageIndex++ {
		_, candidate, _, err := ctx.PageDict(context.Background(), pageIndex, false)
		if err != nil {
			return 0, err
		}
		if candidate != nil && *candidate == pageRef {
			return pageIndex, nil
		}
	}
	return 0, fmt.Errorf("destination page reference %s is not in the document", pageRef.PDFString())
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
