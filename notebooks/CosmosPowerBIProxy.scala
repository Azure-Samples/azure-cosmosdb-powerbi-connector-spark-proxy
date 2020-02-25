// Databricks notebook source
dbutils.widgets.text("cosmos-endpoint", "cosmos-account-name")
dbutils.widgets.text("cosmos-database", "db")
dbutils.widgets.text("cosmos-collection", "coll")

// COMMAND ----------

import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.types._
import scala.util.Random

val r = new Random()

def items = Seq("speaker", "laptop", "headphones", "montior") 

def gen_lat() : Double = {
  val u = r.nextDouble();
  val latitude = Math.toDegrees(Math.acos(u*2-1)) - 90;
  
  return latitude
}

def gen_lon() : Double = {
  val v = r.nextDouble();
  val longitude = 360 * v - 180;
  
  return longitude
}

def generateData() : DataFrame = {
  def lat = gen_lat()
  def lon = gen_lon()
  def item = items(r.nextInt(items.length))
  def quantity = r.nextInt(1000)
  
  return sc.parallelize(
    Seq.fill(50000){(lat, lon, item, quantity)}
  ).toDF("lat", "lon", "item", "quantity")
}

// COMMAND ----------

import com.microsoft.azure.cosmosdb.spark.config.Config
import com.microsoft.azure.cosmosdb.spark.schema._
import com.microsoft.azure.cosmosdb.spark._
import org.apache.spark.sql.SaveMode

val endpoint = "https://" + dbutils.widgets.get("cosmos-endpoint") + ".documents.azure.com:443/"
val masterkey = dbutils.secrets.get(scope = "MAIN", key = "cosmos-key")
val database = dbutils.widgets.get("cosmos-database")
val collection = dbutils.widgets.get("cosmos-collection")

// Write Configuration
val writeConfig = Config(Map(
  "Endpoint" -> endpoint,
  "Masterkey" -> masterkey,
  "Database" -> database,
  "Collection" -> collection,
  "Upsert" -> "true"
))

val data = generateData()

// Write data to Cosmos DB to set up the workflow, in a real scenario there would already be data in the account
data.write.mode(SaveMode.Overwrite).cosmosDB(writeConfig)

// COMMAND ----------

spark.sql(s"CREATE TABLE cosmosdata USING com.microsoft.azure.cosmosdb.spark options (endpoint '$endpoint', database '$database', collection '$collection', masterkey '$masterkey')")
