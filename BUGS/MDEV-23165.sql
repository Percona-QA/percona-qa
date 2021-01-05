USE test;
SET GLOBAL innodb_limit_optimistic_INSERT_debug=2;
CREATE TABLE t (c INT, INDEX(c)) ENGINE=InnoDB;
REPLACE t VALUES (1),(1),(2),(3),(4),(5),(NULL);
INSERT INTO t VALUES (10000),(1),(1.1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1);
INSERT INTO t VALUES (10000),(1),(1.1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1);
INSERT INTO t VALUES (10000),(1),(1.1),(1),(1),(1),(1),(1),(1),(1),(1),(1),(1);
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t VALUES (NULL),(1);
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;  # Approx crash location
INSERT INTO t SELECT * FROM t; 
INSERT INTO t SELECT * FROM t; 

SET SQL_MODE='';
USE test;
SET GLOBAL innodb_limit_optimistic_INSERT_debug=2;
CREATE TABLE t (a INT,b VARCHAR(20),KEY(a));
INSERT INTO t (a) VALUES ('a'),('b'),('c'),('d'),('e');
INSERT INTO t VALUES (1,''),(2,''),(3,''),(4,''),(5,''),(6,''),(7,'');
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT a,a FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;
INSERT INTO t SELECT * FROM t;

USE test;
CREATE TABLE t1 (a int not null primary key) ;
SET @commands= 'abcdefghijklmnopqrstuvwxyz';
set global innodb_simulate_comp_failures=99;
INSERT INTO t1  VALUES(1);
SET @@GLOBAL.OPTIMIZER_SWITCH="mrr=OFF";
INSERT INTO t1  VALUES ('abcdefghijklmnopqrstuvwxyz');
INSERT INTO t1  VALUES(0xA6E0);
ALTER TABLE t1 ROW_FORMAT=DEFAULT KEY_BLOCK_SIZE=2;
CREATE DEFINER=CURRENT_USER FUNCTION f3 (i1 DATETIME(2)) RETURNS DECIMAL(1) UNSIGNED SQL SECURITY INVOKER RETURN CONCAT('abcdefghijklmnopqrstuvwxyz',i1);

USE test;
CREATE TABLE t (a INT PRIMARY KEY);
SET GLOBAL innodb_simulate_comp_failures=99;
INSERT INTO t VALUES(1);
INSERT INTO t VALUES(0);
ALTER TABLE t ROW_FORMAT=DEFAULT KEY_BLOCK_SIZE=2;

SET SQL_MODE='';
USE test;
CREATE TABLE tab(c INT) ROW_FORMAT=COMPRESSED;
SET GLOBAL INNODB_LIMIT_OPTIMISTIC_INSERT_DEBUG=2;
CREATE TABLE t (c INT);
INSERT INTO t VALUES (1),(2),(3),(4);
INSERT INTO t SELECT t.* FROM t,t t2,t t3,t t4,t t5,t t6,t t7;
SET GLOBAL INNODB_RANDOM_READ_AHEAD=1;
INSERT INTO tab(c) VALUES(1);

CREATE TABLE t1 (ID INT(11) NOT NULL AUTO_INCREMENT, Name CHAR(35) NOT NULL DEFAULT '', country CHAR(3) NOT NULL DEFAULT '', Population INT(11) NOT NULL DEFAULT '0', PRIMARY KEY(ID), INDEX (Population), INDEX (country));
SET GLOBAL innodb_limit_optimistic_insert_debug = 2;
INSERT INTO  t1  VALUES (201,'Sarajevo','BIH',360000), (202,'Banja Luka','BIH',143079), (203,'Zenica','BIH',96027), (204,'Gaborone','BWA',213017), (205,'Francistown','BWA',101805), (206,'São Paulo','BRA',9968485), (207,'Rio de Janeiro','BRA',5598953), (208,'Salvador','BRA',2302832), (209,'Belo Horizonte','BRA',2139125), (210,'Fortaleza','BRA',2097757), (211,'Brasília','BRA',1969868), (212,'Curitiba','BRA',1584232), (213,'Recife','BRA',1378087), (214,'Porto Alegre','BRA',1314032), (215,'Manaus','BRA',1255049), (216,'Belém','BRA',1186926), (217,'Guarulhos','BRA',1095874), (218,'Goiânia','BRA',1056330), (219,'Campinas','BRA',950043), (220,'São Gonçalo','BRA',869254), (221,'Nova Iguaçu','BRA',862225), (222,'São Luís','BRA',837588), (223,'Maceió','BRA',786288), (224,'Duque de Caxias','BRA',746758), (225,'São Bernardo do Campo','BRA',723132), (226,'Teresina','BRA',691942), (227,'Natal','BRA',688955), (228,'Osasco','BRA',659604), (229,'Campo Grande','BRA',649593), (230,'Santo André','BRA',630073), (231,'João Pessoa','BRA',584029), (232,'Jaboatão dos Guararapes','BRA',558680), (233,'Contagem','BRA',520801), (234,'São José dos Campos','BRA',515553), (235,'Uberlândia','BRA',487222), (236,'Feira de Santana','BRA',479992), (237,'Ribeirão Preto','BRA',473276), (238,'Sorocaba','BRA',466823), (239,'Niterói','BRA',459884), (240,'Cuiabá','BRA',453813), (241,'Juiz de Fora','BRA',450288), (242,'Aracaju','BRA',445555), (243,'São João de Meriti','BRA',440052), (244,'Londrina','BRA',432257), (245,'Joinville','BRA',428011), (246,'Belford Roxo','BRA',425194), (247,'Santos','BRA',408748), (248,'Ananindeua','BRA',400940), (249,'Campos dos Goytacazes','BRA',398418), (250,'Mauá','BRA',375055), (251,'Carapicuíba','BRA',357552), (252,'Olinda','BRA',354732), (253,'Campina Grande','BRA',352497), (254,'São José do Rio Preto','BRA',351944), (255,'Caxias do Sul','BRA',349581), (256,'Moji das Cruzes','BRA',339194), (257,'Diadema','BRA',335078), (258,'Aparecida de Goiânia','BRA',324662), (259,'Piracicaba','BRA',319104), (260,'Cariacica','BRA',319033), (261,'Vila Velha','BRA',318758), (262,'Pelotas','BRA',315415), (263,'Bauru','BRA',313670), (264,'Porto Velho','BRA',309750), (265,'Serra','BRA',302666), (266,'Betim','BRA',302108), (267,'Jundíaí','BRA',296127), (268,'Canoas','BRA',294125), (269,'Franca','BRA',290139), (270,'São Vicente','BRA',286848), (271,'Maringá','BRA',286461), (272,'Montes Claros','BRA',286058), (273,'Anápolis','BRA',282197), (274,'Florianópolis','BRA',281928), (275,'Petrópolis','BRA',279183), (276,'Itaquaquecetuba','BRA',270874), (277,'Vitória','BRA',270626), (278,'Ponta Grossa','BRA',268013), (279,'Rio Branco','BRA',259537), (280,'Foz do Iguaçu','BRA',259425), (281,'Macapá','BRA',256033), (282,'Ilhéus','BRA',254970), (283,'Vitória da Conquista','BRA',253587), (284,'Uberaba','BRA',249225), (285,'Paulista','BRA',248473), (286,'Limeira','BRA',245497), (287,'Blumenau','BRA',244379), (288,'Caruaru','BRA',244247), (289,'Santarém','BRA',241771), (290,'Volta Redonda','BRA',240315), (291,'Novo Hamburgo','BRA',239940), (292,'Caucaia','BRA',238738), (293,'Santa RocksDB','BRA',238473), (294,'Cascavel','BRA',237510), (295,'Guarujá','BRA',237206), (296,'Ribeirão das Neves','BRA',232685), (297,'Governador Valadares','BRA',231724), (298,'Taubaté','BRA',229130), (299,'Imperatriz','BRA',224564), (300,'Gravataí','BRA',223011), (301,'Embu','BRA',222223), (302,'Mossoró','BRA',214901), (303,'Várzea Grande','BRA',214435), (304,'Petrolina','BRA',210540), (305,'Barueri','BRA',208426), (306,'Viamão','BRA',207557), (307,'Ipatinga','BRA',206338), (308,'Juazeiro','BRA',201073), (309,'Juazeiro do Norte','BRA',199636), (310,'Taboão da Serra','BRA',197550), (311,'São José dos Pinhais','BRA',196884), (312,'Magé','BRA',196147), (313,'Suzano','BRA',195434), (314,'São Leopoldo','BRA',189258), (315,'Marília','BRA',188691), (316,'São Carlos','BRA',187122), (317,'Sumaré','BRA',186205), (318,'Presidente Prudente','BRA',185340), (319,'Divinópolis','BRA',185047), (320,'Sete Lagoas','BRA',182984), (321,'Rio Grande','BRA',182222), (322,'Itabuna','BRA',182148), (323,'Jequié','BRA',179128), (324,'Arapiraca','BRA',178988), (325,'Colombo','BRA',177764), (326,'Americana','BRA',177409), (327,'Alvorada','BRA',175574), (328,'Araraquara','BRA',174381), (329,'Itaboraí','BRA',173977), (330,'Santa Bárbara d´Oeste','BRA',171657), (331,'Nova Friburgo','BRA',170697), (332,'Jacareí','BRA',170356), (333,'Araçatuba','BRA',169303), (334,'Barra Mansa','BRA',168953), (335,'Praia Grande','BRA',168434), (336,'Marabá','BRA',167795), (337,'Criciúma','BRA',167661), (338,'Boa Vista','BRA',167185), (339,'Passo Fundo','BRA',166343), (340,'Dourados','BRA',164716), (341,'Santa Luzia','BRA',164704), (342,'Rio Claro','BRA',163551), (343,'Maracanaú','BRA',162022), (344,'Guarapuava','BRA',160510), (345,'Rondonópolis','BRA',155115), (346,'São José','BRA',155105), (347,'Cachoeiro de Itapemirim','BRA',155024), (348,'Nilópolis','BRA',153383), (349,'Itapevi','BRA',150664), (350,'Cabo de Santo Agostinho','BRA',149964), (351,'Camaçari','BRA',149146), (352,'Sobral','BRA',146005), (353,'Itajaí','BRA',145197), (354,'Chapecó','BRA',144158), (355,'Cotia','BRA',140042), (356,'Lages','BRA',139570), (357,'Ferraz de Vasconcelos','BRA',139283), (358,'Indaiatuba','BRA',135968), (359,'Hortolândia','BRA',135755), (360,'Caxias','BRA',133980), (361,'São Caetano do Sul','BRA',133321), (362,'Itu','BRA',132736), (363,'Nossa Senhora do Socorro','BRA',131351), (364,'Parnaíba','BRA',129756), (365,'Poços de Caldas','BRA',129683), (366,'Teresópolis','BRA',128079), (367,'Barreiras','BRA',127801), (368,'Castanhal','BRA',127634), (369,'Alagoinhas','BRA',126820), (370,'Itapecerica da Serra','BRA',126672), (371,'Uruguaiana','BRA',126305), (372,'Paranaguá','BRA',126076), (373,'Ibirité','BRA',125982), (374,'Timon','BRA',125812), (375,'Luziânia','BRA',125597), (376,'Macaé','BRA',125597), (377,'Teófilo Otoni','BRA',124489), (378,'Moji-Guaçu','BRA',123782), (379,'Palmas','BRA',121919), (380,'Pindamonhangaba','BRA',121904), (381,'Francisco Morato','BRA',121197), (382,'Bagé','BRA',120793), (383,'Sapucaia do Sul','BRA',120217), (384,'Cabo Frio','BRA',119503), (385,'Itapetininga','BRA',119391), (386,'Patos de Minas','BRA',119262), (387,'Camaragibe','BRA',118968), (388,'Bragança Paulista','BRA',116929), (389,'Queimados','BRA',115020), (390,'Araguaína','BRA',114948), (391,'Garanhuns','BRA',114603), (392,'Vitória de Santo Antão','BRA',113595), (393,'Santa Rita','BRA',113135), (394,'Barbacena','BRA',113079), (395,'Abaetetuba','BRA',111258), (396,'Jaú','BRA',109965), (397,'Lauro de Freitas','BRA',109236), (398,'Franco da Rocha','BRA',108964), (399,'Teixeira de Freitas','BRA',108441), (400,'Varginha','BRA',108314);
