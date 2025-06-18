mlir-faust-signals.pdf : mlir-faust-signals.md examples/*.dsp
	make -C examples
	pandoc mlir-faust-signals.md -o mlir-faust-signals.pdf --from markdown --template=eisvogel --listings

clean:
	rm -f mlir-faust-signals.pdf
	make -C examples clean



