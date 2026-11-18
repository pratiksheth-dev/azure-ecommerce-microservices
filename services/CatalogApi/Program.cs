// Built by Pratik Sheth — sample portfolio project.
// Catalog API: a small .NET 8 minimal API that owns the product catalog.
// The Orders API calls this service over HTTP; it is the system of record
// for product names, prices, and stock in this sample.

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

// In-memory catalog for the sample. A production version would read from
// Azure SQL (see infra/main.bicep) behind a repository, with this service
// remaining the only writer/reader of product data.
var products = new List<Product>
{
    new(1, "Wireless Noise-Cancelling Headphones", "SKU-1001", 199.99m, 25),
    new(2, "Mechanical Keyboard", "SKU-1002", 129.50m, 40),
    new(3, "USB-C Docking Station", "SKU-1003", 249.00m, 12),
    new(4, "1080p USB Webcam", "SKU-1004", 79.99m, 60)
};

app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "catalog-api" }));

app.MapGet("/api/products", () => Results.Ok(products));

app.MapGet("/api/products/{id:int}", (int id) =>
{
    var product = products.FirstOrDefault(p => p.Id == id);
    return product is null ? Results.NotFound() : Results.Ok(product);
});

app.MapPost("/api/products", (CreateProductRequest request) =>
{
    if (string.IsNullOrWhiteSpace(request.Name) || request.Price < 0)
        return Results.BadRequest(new { detail = "A name and a non-negative price are required." });

    var id = products.Count == 0 ? 1 : products.Max(p => p.Id) + 1;
    var product = new Product(id, request.Name, request.Sku, request.Price, request.StockQuantity);
    products.Add(product);

    return Results.Created($"/api/products/{product.Id}", product);
});

app.Run();

/// <summary>A catalog product.</summary>
public record Product(int Id, string Name, string Sku, decimal Price, int StockQuantity);

/// <summary>Payload for creating a product.</summary>
public record CreateProductRequest(string Name, string Sku, decimal Price, int StockQuantity);
